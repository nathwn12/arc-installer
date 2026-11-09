using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;

// A payload that fails verification never reaches the install tree. Its own
// type so Main can name the cause and exit non-zero instead of dying with an
// unhandled exception (a winexe would show a crash box and leave files behind).
sealed class PayloadIntegrityException : Exception
{
    public PayloadIntegrityException(string message) : base(message) { }
}

static class Program
{
    // Exit codes: 2 = embedded payload failed verification (nothing written),
    // 3 = extraction/install failed for another reason. 1 is still the
    // --selftest and --cli failure code.
    private const int ExitPayloadUntrusted = 2;
    private const int ExitExtractFailed = 3;

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--selftest")
        {
            return DoSelfTest();
        }
        bool cli = args.Length > 0 && args[0] == "--cli";
        // --extract is the headless seam tests and the release lane use to run
        // the real launch path (verify, then extract, then stop) without the UI
        // and without running ARC-Icons.ps1. It writes only the tool tree.
        bool extractOnly = args.Length > 0 && args[0] == "--extract";
        try
        {
            EnsureToolTree();
        }
        catch (PayloadIntegrityException ex)
        {
            ReportFatal("payload verification failed: " + ex.Message);
            return ExitPayloadUntrusted;
        }
        catch (Exception ex)
        {
            ReportFatal("payload extraction failed: " + ex.Message);
            return ExitExtractFailed;
        }
        if (extractOnly)
        {
            return 0;
        }
        if (cli)
        {
            return DoCli(args);
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        MainForm f = new MainForm();
        Application.Run(f);
        return 0;
    }

    // A failed launch must still name its reason. stderr carries it for --cli,
    // --extract and any redirected caller; a person double-clicking a winexe
    // gets the same text in a box. A redirected stderr means a machine is
    // listening, so no box is shown then (tests would otherwise block on it).
    static void ReportFatal(string message)
    {
        try
        {
            Console.Error.WriteLine("ArcInstaller: " + message);
        }
        catch
        {
        }
        try
        {
            if (!Console.IsErrorRedirected)
            {
                MessageBox.Show(message, "ArcInstaller", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
        catch
        {
        }
    }

    static string GetToolRoot()
    {
        // Test seam only: the real launch always installs under ProgramData.
        // The embedded payload is verified either way, so an override cannot
        // smuggle bytes into the target tree; it only redirects the target.
        string overrideRoot = Environment.GetEnvironmentVariable("ARCINSTALLER_TOOL_ROOT");
        if (!string.IsNullOrEmpty(overrideRoot))
        {
            return Path.GetFullPath(overrideRoot);
        }
        string baseDir = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        return Path.Combine(baseDir, "ArcIcons");
    }

    static string PowershellPath()
    {
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (string.IsNullOrEmpty(sysRoot))
        {
            sysRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        }
        string candidate = Path.Combine(sysRoot, "System32");
        candidate = Path.Combine(candidate, "WindowsPowerShell");
        candidate = Path.Combine(candidate, "v1.0");
        candidate = Path.Combine(candidate, "powershell.exe");
        if (File.Exists(candidate))
        {
            return candidate;
        }
        return "powershell.exe";
    }

    internal static string WinPsModulePath()
    {
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (string.IsNullOrEmpty(sysRoot))
        {
            sysRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        }
        string candidate = Path.Combine(sysRoot, "System32");
        candidate = Path.Combine(candidate, "WindowsPowerShell");
        candidate = Path.Combine(candidate, "v1.0");
        candidate = Path.Combine(candidate, "Modules");
        return candidate;
    }

    static string ToHex(byte[] data)
    {
        StringBuilder sb = new StringBuilder(data.Length * 2);
        for (int i = 0; i < data.Length; i++)
        {
            sb.Append(data[i].ToString("X2"));
        }
        return sb.ToString();
    }

    static string HashFile(string path)
    {
        using (SHA256 sha = SHA256.Create())
        {
            using (FileStream fs = File.OpenRead(path))
            {
                return ToHex(sha.ComputeHash(fs));
            }
        }
    }

    static string HashStream(Stream s)
    {
        using (SHA256 sha = SHA256.Create())
        {
            return ToHex(sha.ComputeHash(s));
        }
    }

    private const string ManifestEntryName = "payload-manifest.json";

    // Decompressed-size ceiling for the embedded payload, enforced before a
    // single entry is decompressed. Measured on this build (2026-11-07):
    // staging\files holds 51 files totalling 172,570,225 bytes (164.6 MiB);
    // 4x that is 690,280,900 bytes, and 704 MiB leaves headroom for a theme
    // revision that adds a few icon packs while still refusing a bomb (a 4 GiB
    // payload is ~6x over). Raise it only with a new measurement in this comment.
    private const long PayloadUncompressedCap = 704L * 1024 * 1024;

    static bool IsHex64(string s)
    {
        if (s == null || s.Length != 64)
        {
            return false;
        }
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
            if (!hex)
            {
                return false;
            }
        }
        return true;
    }

    static string NormalizeArchivePath(string name)
    {
        return name.Replace('\\', '/');
    }

    // Manifest and archive paths are relative and forward-slashed by build.ps1.
    // Anything absolute, drive-qualified or carrying a ".." component is not a
    // file this installer ever ships, so it fails closed instead of being
    // silently skipped.
    static bool IsUnsafeRelativePath(string rel)
    {
        if (string.IsNullOrEmpty(rel))
        {
            return true;
        }
        if (rel[0] == '/')
        {
            return true;
        }
        if (rel.Length >= 2 && rel[1] == ':')
        {
            return true;
        }
        string[] parts = rel.Split('/');
        for (int i = 0; i < parts.Length; i++)
        {
            if (parts[i] == ".." || parts[i] == ".")
            {
                return true;
            }
        }
        return false;
    }

    static byte[] ReadAllBytes(Stream s)
    {
        using (MemoryStream mem = new MemoryStream())
        {
            s.CopyTo(mem);
            return mem.ToArray();
        }
    }

    // The one payload gate. Called on every launch (GUI, --cli, --extract) and
    // by --selftest, before any file is created. Returns the SHA-256 this
    // archive must produce for every entry, including the manifest itself, so
    // extraction can verify the bytes it writes instead of trusting them.
    //
    // Checks, in order: entry paths stay under the install root, the sum of
    // declared sizes fits the zip-bomb cap, payload-manifest.json exists and
    // parses, every manifest row names a file with a well-formed digest, every
    // archive entry has a row, every entry hashes to its row, and every row has
    // an entry. First failure throws with the path and both digests.
    static Dictionary<string, string> ValidatePayloadArchive(ZipArchive z)
    {
        long total = 0;
        int files = 0;
        foreach (ZipArchiveEntry e in z.Entries)
        {
            if (string.IsNullOrEmpty(e.Name))
            {
                continue; // directory entry
            }
            files++;
            string rel = NormalizeArchivePath(e.FullName);
            if (IsUnsafeRelativePath(rel))
            {
                throw new PayloadIntegrityException(
                    "payload entry '" + e.FullName + "' escapes the install root");
            }
            total += e.Length;
            if (total > PayloadUncompressedCap)
            {
                throw new PayloadIntegrityException(
                    "payload expands past the " + PayloadUncompressedCap.ToString() +
                    "-byte cap (zip-bomb guard) at entry '" + e.FullName + "'");
            }
        }
        if (files == 0)
        {
            throw new PayloadIntegrityException("embedded payload.zip carries no file entries");
        }

        ZipArchiveEntry manEntry = null;
        foreach (ZipArchiveEntry e in z.Entries)
        {
            if (string.Equals(NormalizeArchivePath(e.FullName), ManifestEntryName, StringComparison.OrdinalIgnoreCase))
            {
                manEntry = e;
                break;
            }
        }
        if (manEntry == null)
        {
            throw new PayloadIntegrityException(
                "'" + ManifestEntryName + "' is missing from the embedded payload");
        }

        byte[] manBytes;
        try
        {
            using (Stream ms = manEntry.Open())
            {
                manBytes = ReadAllBytes(ms);
            }
        }
        catch (Exception ex)
        {
            throw new PayloadIntegrityException(
                "'" + ManifestEntryName + "' is unreadable: " + ex.Message);
        }
        string json;
        try
        {
            using (StreamReader sr = new StreamReader(new MemoryStream(manBytes), Encoding.UTF8, true))
            {
                json = sr.ReadToEnd();
            }
        }
        catch (Exception ex)
        {
            throw new PayloadIntegrityException(
                "'" + ManifestEntryName + "' is unreadable: " + ex.Message);
        }
        if (string.IsNullOrEmpty(json))
        {
            throw new PayloadIntegrityException(
                "'" + ManifestEntryName + "' is empty");
        }

        List<string[]> pairs = ParseManifestPairs(json);
        if (pairs.Count == 0)
        {
            throw new PayloadIntegrityException(
                "'" + ManifestEntryName + "' records no files");
        }

        Dictionary<string, string> rows = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string[] pair in pairs)
        {
            string rel = NormalizeArchivePath(pair[0]);
            string want = pair[1];
            if (IsUnsafeRelativePath(rel))
            {
                throw new PayloadIntegrityException(
                    "'" + ManifestEntryName + "' row '" + pair[0] + "' escapes the install root");
            }
            if (string.Equals(rel, ManifestEntryName, StringComparison.OrdinalIgnoreCase))
            {
                throw new PayloadIntegrityException(
                    "'" + ManifestEntryName + "' records itself; it must list payload files only");
            }
            if (!IsHex64(want))
            {
                throw new PayloadIntegrityException(
                    "'" + ManifestEntryName + "' row '" + pair[0] + "' has a malformed sha256");
            }
            if (rows.ContainsKey(rel))
            {
                throw new PayloadIntegrityException(
                    "'" + ManifestEntryName + "' lists '" + pair[0] + "' twice");
            }
            rows.Add(rel, want.ToUpperInvariant());
        }

        Dictionary<string, string> expected = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        // The manifest cannot hash itself, so its own bytes are trusted only to
        // the extent that every row they declare matches the archive. Record
        // the digest of the bytes we actually parsed so extraction still writes
        // exactly what was validated.
        expected.Add(ManifestEntryName, HashBytes(manBytes));
        foreach (ZipArchiveEntry e in z.Entries)
        {
            if (string.IsNullOrEmpty(e.Name))
            {
                continue;
            }
            string rel = NormalizeArchivePath(e.FullName);
            if (string.Equals(rel, ManifestEntryName, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            string want;
            if (!rows.TryGetValue(rel, out want))
            {
                throw new PayloadIntegrityException(
                    "payload entry '" + e.FullName + "' has no '" + ManifestEntryName + "' row");
            }
            string have;
            try
            {
                using (Stream es = e.Open())
                {
                    have = HashStream(es);
                }
            }
            catch (Exception ex)
            {
                throw new PayloadIntegrityException(
                    "payload entry '" + e.FullName + "' is unreadable: " + ex.Message);
            }
            if (!string.Equals(have, want, StringComparison.OrdinalIgnoreCase))
            {
                throw new PayloadIntegrityException(
                    "payload entry '" + e.FullName + "' hashes to " + have +
                    " but '" + ManifestEntryName + "' records " + want);
            }
            expected.Add(rel, want);
        }
        foreach (string rel in rows.Keys)
        {
            if (!expected.ContainsKey(rel))
            {
                throw new PayloadIntegrityException(
                    "'" + ManifestEntryName + "' row '" + rel + "' has no entry in the embedded payload");
            }
        }
        return expected;
    }

    static string HashBytes(byte[] data)
    {
        using (SHA256 sha = SHA256.Create())
        {
            return ToHex(sha.ComputeHash(data));
        }
    }

    static bool HasReparsePoint(string path)
    {
        try
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) == FileAttributes.ReparsePoint;
        }
        catch
        {
            return false;
        }
    }

    // A junction or symlink anywhere on the path to the tool root would send
    // the verified payload somewhere else, so the root is refused if any
    // existing component is a reparse point. Cheap: a few attribute reads.
    static void EnsureSafeToolRoot(string root)
    {
        string cur = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
        while (!string.IsNullOrEmpty(cur))
        {
            if (Directory.Exists(cur) && HasReparsePoint(cur))
            {
                throw new PayloadIntegrityException(
                    "install root component '" + cur + "' is a reparse point; refusing to write through it");
            }
            string parent = Path.GetDirectoryName(cur);
            if (string.IsNullOrEmpty(parent) || parent.Length >= cur.Length)
            {
                break;
            }
            cur = parent;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public uint CreationTimeLow;
        public uint CreationTimeHigh;
        public uint LastAccessTimeLow;
        public uint LastAccessTimeHigh;
        public uint LastWriteTimeLow;
        public uint LastWriteTimeHigh;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation info);

    // An existing destination that is a symlink or has more than one hardlink
    // is not a file this installer wrote: writing through it would land on
    // whatever it points at. Reject rather than repair; the tree is untrusted.
    static void EnsureSafeTarget(string path)
    {
        if (HasReparsePoint(path))
        {
            throw new PayloadIntegrityException(
                "install target '" + path + "' is a reparse point; refusing to write through it");
        }
        uint links;
        try
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                ByHandleFileInformation info;
                if (!GetFileInformationByHandle(fs.SafeFileHandle, out info))
                {
                    throw new IOException("GetFileInformationByHandle failed with error " +
                        Marshal.GetLastWin32Error().ToString());
                }
                links = info.NumberOfLinks;
            }
        }
        catch (PayloadIntegrityException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new PayloadIntegrityException(
                "install target '" + path + "' cannot be inspected: " + ex.Message);
        }
        if (links > 1)
        {
            throw new PayloadIntegrityException(
                "install target '" + path + "' has " + links.ToString() +
                " hardlinks; refusing to write through it");
        }
    }

    // Writes the entry to a sibling temp file, hashes the bytes as they land,
    // and only then moves it into place. The bytes that reach the tool tree are
    // the bytes the manifest already vouched for, never an unverified stream.
    static void WriteVerifiedEntry(ZipArchiveEntry e, string fullDest, string expectedHash)
    {
        string dir = Path.GetDirectoryName(fullDest);
        if (!string.IsNullOrEmpty(dir))
        {
            Directory.CreateDirectory(dir);
        }
        string tmp = fullDest + ".arc-new";
        try
        {
            string have;
            using (Stream es = e.Open())
            {
                using (SHA256 sha = SHA256.Create())
                {
                    using (FileStream fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        byte[] buf = new byte[81920];
                        int n;
                        while ((n = es.Read(buf, 0, buf.Length)) > 0)
                        {
                            sha.TransformBlock(buf, 0, n, buf, 0);
                            fs.Write(buf, 0, n);
                        }
                        sha.TransformFinalBlock(buf, 0, 0);
                        have = ToHex(sha.Hash);
                    }
                }
            }
            if (!string.Equals(have, expectedHash, StringComparison.OrdinalIgnoreCase))
            {
                throw new PayloadIntegrityException(
                    "payload entry '" + e.FullName + "' changed while being extracted" +
                    " (expected " + expectedHash + ", wrote " + have + ")");
            }
            if (File.Exists(fullDest))
            {
                File.Replace(tmp, fullDest, null);
            }
            else
            {
                File.Move(tmp, fullDest);
            }
        }
        catch
        {
            try
            {
                if (File.Exists(tmp))
                {
                    File.Delete(tmp);
                }
            }
            catch
            {
            }
            throw;
        }
    }

    static void EnsureToolTree()
    {
        Assembly asm = Assembly.GetExecutingAssembly();
        using (Stream rs = asm.GetManifestResourceStream("payload.zip"))
        {
            if (rs == null)
            {
                throw new PayloadIntegrityException(
                    "embedded payload.zip is missing from the executable");
            }
            using (ZipArchive z = new ZipArchive(rs, ZipArchiveMode.Read))
            {
                // Verify everything before the first byte is written.
                Dictionary<string, string> expected = ValidatePayloadArchive(z);

                string root = GetToolRoot();
                EnsureSafeToolRoot(root);
                Directory.CreateDirectory(root);
                string fullRoot = Path.GetFullPath(root);
                if (!fullRoot.EndsWith(Path.DirectorySeparatorChar.ToString()))
                {
                    fullRoot = fullRoot + Path.DirectorySeparatorChar;
                }

                foreach (ZipArchiveEntry e in z.Entries)
                {
                    if (string.IsNullOrEmpty(e.Name))
                    {
                        continue;
                    }
                    string rel = NormalizeArchivePath(e.FullName);
                    string dest = Path.Combine(root, rel.Replace('/', Path.DirectorySeparatorChar));
                    string fullDest = Path.GetFullPath(dest);
                    if (!fullDest.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase))
                    {
                        continue; // validator already refuses these; belt and braces
                    }
                    string want;
                    if (!expected.TryGetValue(rel, out want))
                    {
                        throw new PayloadIntegrityException(
                            "payload entry '" + e.FullName + "' was not verified");
                    }
                    bool need = true;
                    if (File.Exists(fullDest))
                    {
                        EnsureSafeTarget(fullDest);
                        string have = HashFile(fullDest);
                        if (string.Equals(want, have, StringComparison.OrdinalIgnoreCase))
                        {
                            need = false;
                        }
                    }
                    if (need)
                    {
                        WriteVerifiedEntry(e, fullDest, want);
                    }
                }
            }
        }
    }

    static int DoSelfTest()
    {
        try
        {
            int pid = Process.GetCurrentProcess().Id;
            string tmp = Path.GetTempPath();
            string dir = Path.Combine(tmp, "arcinstaller-selftest-" + pid.ToString());
            if (Directory.Exists(dir))
            {
                Directory.Delete(dir, true);
            }
            string fullDir = Path.GetFullPath(dir);
            if (!fullDir.EndsWith(Path.DirectorySeparatorChar.ToString()))
            {
                fullDir = fullDir + Path.DirectorySeparatorChar;
            }
            int count = 0;
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream rs = asm.GetManifestResourceStream("payload.zip"))
            {
                if (rs == null)
                {
                    Console.WriteLine("selftest FAIL missing payload.zip");
                    return 1;
                }
                using (ZipArchive z = new ZipArchive(rs, ZipArchiveMode.Read))
                {
                    // Same gate the real launch runs, ahead of any extraction,
                    // so a tampered payload fails here without leaving a file.
                    try
                    {
                        ValidatePayloadArchive(z);
                    }
                    catch (PayloadIntegrityException ex)
                    {
                        Console.WriteLine("selftest FAIL " + ex.Message);
                        return 1;
                    }
                    Directory.CreateDirectory(dir);
                    foreach (ZipArchiveEntry e in z.Entries)
                    {
                        if (string.IsNullOrEmpty(e.Name))
                        {
                            continue;
                        }
                        string rel = e.FullName.Replace('/', Path.DirectorySeparatorChar);
                        string dest = Path.Combine(dir, rel);
                        string fullDest = Path.GetFullPath(dest);
                        if (!fullDest.StartsWith(fullDir, StringComparison.OrdinalIgnoreCase))
                        {
                            continue;
                        }
                        string d = Path.GetDirectoryName(fullDest);
                        if (!string.IsNullOrEmpty(d))
                        {
                            Directory.CreateDirectory(d);
                        }
                        using (Stream es = e.Open())
                        {
                            using (FileStream fs = new FileStream(fullDest, FileMode.Create, FileAccess.Write, FileShare.None))
                            {
                                es.CopyTo(fs);
                            }
                        }
                        count++;
                    }
                }
            }
            Console.WriteLine("entries: " + count.ToString());
            string[] samples = new string[]
            {
                "ARC-Icons.ps1",
                Path.Combine("bin", "Set-BaselineSecurity.ps1"),
                Path.Combine(Path.Combine("theme", "Windhawk Resources"), "imageres.dll")
            };
            bool ok = true;
            for (int i = 0; i < samples.Length; i++)
            {
                string p = Path.Combine(dir, samples[i]);
                if (!File.Exists(p))
                {
                    Console.WriteLine("sample missing " + samples[i]);
                    ok = false;
                }
                else
                {
                    string h = HashFile(p);
                    Console.WriteLine("sample " + samples[i] + " " + h);
                }
            }
            if (!ok)
            {
                return 1;
            }
            if (count <= 0)
            {
                return 1;
            }
            // Payload integrity: every extracted file must match the hash
            // build.ps1 recorded in payload-manifest.json. Extraction alone
            // proves nothing about content; this closes that gap.
            string manPath = Path.Combine(dir, "payload-manifest.json");
            if (!File.Exists(manPath))
            {
                Console.WriteLine("selftest FAIL payload-manifest.json missing");
                return 1;
            }
            List<string[]> pairs = ParseManifestPairs(File.ReadAllText(manPath, Encoding.UTF8));
            if (pairs.Count == 0)
            {
                Console.WriteLine("selftest FAIL payload-manifest.json carries no entries");
                return 1;
            }
            int verified = 0;
            foreach (string[] pair in pairs)
            {
                string rel = pair[0].Replace('/', Path.DirectorySeparatorChar);
                string full = Path.GetFullPath(Path.Combine(dir, rel));
                string want = pair[1];
                if (!full.StartsWith(fullDir, StringComparison.OrdinalIgnoreCase) || !File.Exists(full))
                {
                    Console.WriteLine("manifest missing " + pair[0]);
                    ok = false;
                    continue;
                }
                string have = HashFile(full);
                if (!string.Equals(have, want, StringComparison.OrdinalIgnoreCase))
                {
                    Console.WriteLine("manifest MISMATCH " + pair[0]);
                    ok = false;
                    continue;
                }
                verified++;
            }
            // No extra files beyond the manifest (drift visible both ways).
            string[] onDisk = Directory.GetFiles(dir, "*", SearchOption.AllDirectories);
            int extra = 0;
            foreach (string f in onDisk)
            {
                if (string.Equals(Path.GetFileName(f), "payload-manifest.json", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                extra++;
            }
            Console.WriteLine("manifest: " + verified.ToString() + "/" + pairs.Count.ToString() + " files verified");
            if (!ok || extra != pairs.Count || verified != pairs.Count)
            {
                if (extra != pairs.Count)
                {
                    Console.WriteLine("selftest FAIL on-disk file count " + extra.ToString() + " != manifest " + pairs.Count.ToString());
                }
                return 1;
            }
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine("selftest FAIL " + ex.Message);
            return 1;
        }
    }

    static string QuoteArg(string a)
    {
        if (a.Length == 0)
        {
            return "\"\"";
        }
        bool need = false;
        for (int i = 0; i < a.Length; i++)
        {
            char ch = a[i];
            if (ch == ' ' || ch == '\t' || ch == '"')
            {
                need = true;
                break;
            }
        }
        if (!need)
        {
            return a;
        }
        return "\"" + a.Replace("\"", "\"\"") + "\"";
    }

    static int DoCli(string[] args)
    {
        try
        {
            string controller = Path.Combine(GetToolRoot(), "ARC-Icons.ps1");
            StringBuilder sb = new StringBuilder();
            sb.Append("-NoProfile -ExecutionPolicy Bypass -File ");
            sb.Append(QuoteArg(controller));
            for (int i = 1; i < args.Length; i++)
            {
                sb.Append(" ");
                sb.Append(QuoteArg(args[i]));
            }
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = PowershellPath();
            psi.Arguments = sb.ToString();
            psi.UseShellExecute = false;
            psi.EnvironmentVariables["PSModulePath"] = WinPsModulePath();
            Process p = Process.Start(psi);
            p.WaitForExit();
            int code = p.ExitCode;
            p.Close();
            return code;
        }
        catch (Exception ex)
        {
            Console.WriteLine("cli FAIL " + ex.Message);
            return 1;
        }
    }

    // Minimal manifest reader: payload-manifest.json is written by build.ps1 as
    // {"generated": "...", "files": [{"path": "...", "sha256": "..."}, ...]}.
    // No JSON library on this target; entries are read as ordered path/sha256
    // pairs and every value is re-checked by the caller. Never trusts shape.
    static List<string[]> ParseManifestPairs(string json)
    {
        List<string[]> pairs = new List<string[]>();
        int i = 0;
        while (true)
        {
            int kp = json.IndexOf("\"path\"", i, StringComparison.Ordinal);
            if (kp < 0)
            {
                break;
            }
            int cp = json.IndexOf(':', kp + 6);
            if (cp < 0)
            {
                break;
            }
            string path = ReadQuoted(json, cp + 1);
            if (path == null)
            {
                break;
            }
            int ks = json.IndexOf("\"sha256\"", cp, StringComparison.Ordinal);
            if (ks < 0)
            {
                break;
            }
            int cs = json.IndexOf(':', ks + 8);
            if (cs < 0)
            {
                break;
            }
            string hash = ReadQuoted(json, cs + 1);
            if (hash == null)
            {
                break;
            }
            pairs.Add(new string[] { path, hash });
            i = cs + 1;
        }
        return pairs;
    }

    static string ReadQuoted(string json, int from)
    {
        int q1 = json.IndexOf('"', from);
        if (q1 < 0)
        {
            return null;
        }
        // Manifest values come from file names and hex digests; no escape
        // handling is needed, and an escape would fail closed below.
        int q2 = json.IndexOf('"', q1 + 1);
        if (q2 < 0)
        {
            return null;
        }
        string v = json.Substring(q1 + 1, q2 - q1 - 1);
        if (v.IndexOf('\\') >= 0)
        {
            return null;
        }
        return v;
    }

    static string ExtractJsonValue(string json, string key)
    {
        string qkey = "\"" + key + "\"";
        int i = json.IndexOf(qkey, StringComparison.Ordinal);
        if (i < 0)
        {
            return null;
        }
        int c = json.IndexOf(':', i + qkey.Length);
        if (c < 0)
        {
            return null;
        }
        int q1 = json.IndexOf('"', c + 1);
        if (q1 < 0)
        {
            return null;
        }
        int q2 = json.IndexOf('"', q1 + 1);
        if (q2 < 0)
        {
            return null;
        }
        return json.Substring(q1 + 1, q2 - q1 - 1);
    }

    public static string StatusText(string toolRoot)
    {
        try
        {
            string man = Path.Combine(toolRoot, "installed-manifest.json");
            if (!File.Exists(man))
            {
                return "not installed";
            }
            string json = File.ReadAllText(man, Encoding.UTF8);
            string theme = ExtractJsonValue(json, "theme");
            string vid = ExtractJsonValue(json, "variantId");
            string gen = ExtractJsonValue(json, "generated");
            if (string.IsNullOrEmpty(theme) && string.IsNullOrEmpty(vid) && string.IsNullOrEmpty(gen))
            {
                return "installed-manifest unreadable";
            }
            string t = theme;
            if (string.IsNullOrEmpty(t))
            {
                t = "?";
            }
            string g = HumanizeStamp(gen);
            if (string.IsNullOrEmpty(g))
            {
                g = "?";
            }
            return t + "  ·  installed " + g;
        }
        catch (Exception ex)
        {
            return "unreadable: " + ex.Message;
        }
    }

    // Display-only: the manifest stores a round-trip ISO stamp; a person reads
    // "15:16", not "2026-10-14T15:16:47.9091925+08:00". Never rewrites state.
    static string HumanizeStamp(string iso)
    {
        if (string.IsNullOrEmpty(iso))
        {
            return "";
        }
        DateTime dt;
        if (!DateTime.TryParse(iso, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out dt))
        {
            return iso;
        }
        DateTime local = dt.ToLocalTime();
        if (local.Date == DateTime.Today)
        {
            return local.ToString("HH:mm");
        }
        return local.ToString("d MMM HH:mm");
    }

    // Read-only accessor for the UI: the installed variant id, or "" when the
    // manifest is absent or unreadable. Never writes state.
    public static string InstalledVariantId(string toolRoot)
    {
        try
        {
            string man = Path.Combine(toolRoot, "installed-manifest.json");
            if (!File.Exists(man))
            {
                return "";
            }
            string json = File.ReadAllText(man, Encoding.UTF8);
            string vid = ExtractJsonValue(json, "variantId");
            return vid == null ? "" : vid;
        }
        catch
        {
            return "";
        }
    }
}

class MainForm : Form
{
    // One dark palette, used everywhere: the state dot and the failure bar are
    // the only places colour carries meaning, and both always sit beside words.
    private static readonly Color Bg = Color.FromArgb(0x1E, 0x1E, 0x1E);
    private static readonly Color Fg = Color.FromArgb(0xE8, 0xE8, 0xE8);
    private static readonly Color PanelBg = Color.FromArgb(0x2D, 0x2D, 0x2D);
    private static readonly Color EditBg = Color.FromArgb(0x25, 0x25, 0x26);
    private static readonly Color Accent = Color.FromArgb(0x2F, 0x6F, 0x9E);
    private static readonly Color Sub = Color.FromArgb(0xA8, 0xA8, 0xA8);
    private static readonly Color Healthy = Color.FromArgb(0x4C, 0xAF, 0x50);
    private static readonly Color Unknown = Color.FromArgb(0xD7, 0xA4, 0x3C);
    private static readonly Color Danger = Color.FromArgb(0xE5, 0x53, 0x4B);
    private static readonly Color DangerBar = Color.FromArgb(0x3A, 0x22, 0x22);

    private const int DesignWidth = 560;

    private ComboBox variantBox;
    private Button installBtn;
    private Button statusBtn;
    private Button moreBtn;
    private ContextMenuStrip moreMenu;
    private Button detailsBtn;
    private Label variantLabel;
    private Label variantCaption;
    private Label stateDot;
    private Label stateLine1;
    private Label stateLine2;
    private Panel failureBar;
    private Label failLabel;
    private LinkLabel showDetailsLink;
    private TextBox outputBox;
    private PictureBox previewBox;

    private string toolRoot;
    private string[] ids;
    private string[] labels;
    private string[] themeDirs;

    private Color dotColor = Sub;
    private bool detailsOpen;
    private bool failureVisible;
    // 0 until measured from the autoscaled form width, then held constant so a
    // relayout at 150% keeps its proportions instead of snapping to 96 dpi.
    private float uiScale;
    private bool sawFailureSignal;
    private string firstErrorLine;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibraryEx(string lpFileName, IntPtr hFile, uint dwFlags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeLibrary(IntPtr hModule);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr FindResource(IntPtr hModule, IntPtr lpName, IntPtr lpType);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LoadResource(IntPtr hModule, IntPtr hResInfo);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LockResource(IntPtr hResData);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SizeofResource(IntPtr hModule, IntPtr hResInfo);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern int LookupIconIdFromDirectoryEx(byte[] presbits, bool fIcon, int cxDesired, int cyDesired, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CreateIconFromResourceEx(byte[] presbits, uint dwResSize, bool fIcon, uint dwVer, int cxDesired, int cyDesired, uint flags);
    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr hIcon);

    private const uint LoadLibraryAsDatafile = 0x00000002;
    private const int RtIcon = 3;
    private const int RtGroupIcon = 14;
    // The preview glyph is an RT_GROUP_ICON resource ID, NOT an ExtractIconEx index.
    // Measured against the glyph Explorer actually draws for a plain folder
    // (SHGetFileInfo SHGFI_ICON -> 32x32, meanRGB 90,90,90): ids 3/4/143/190 match
    // it at 95.90% exact ARGB, and id 3 tracks the theme recolor
    // (arc 111,161,221 -> neutral-brown 220,170,111 -> neutral-grey 165,165,165 ->
    // dark-grey 90,90,90). Id 28 is the SD-card glyph and matched nothing.
    private const int FolderGlyphGroupId = 3;

    private static byte[] ReadResourceBytes(IntPtr hMod, IntPtr hRes)
    {
        uint size = SizeofResource(hMod, hRes);
        if (size == 0)
        {
            return null;
        }
        IntPtr p = LockResource(LoadResource(hMod, hRes));
        if (p == IntPtr.Zero)
        {
            return null;
        }
        byte[] buf = new byte[(int)size];
        Marshal.Copy(p, buf, 0, (int)size);
        return buf;
    }

    private static Icon LoadGroupIconById(string dll, int groupId, int size)
    {
        IntPtr hMod = LoadLibraryEx(dll, IntPtr.Zero, LoadLibraryAsDatafile);
        if (hMod == IntPtr.Zero)
        {
            return null;
        }
        try
        {
            IntPtr hGroup = FindResource(hMod, (IntPtr)groupId, (IntPtr)RtGroupIcon);
            if (hGroup == IntPtr.Zero)
            {
                return null;
            }
            byte[] group = ReadResourceBytes(hMod, hGroup);
            if (group == null)
            {
                return null;
            }
            int iconId = LookupIconIdFromDirectoryEx(group, true, size, size, 0);
            if (iconId == 0)
            {
                return null;
            }
            IntPtr hIconRes = FindResource(hMod, (IntPtr)iconId, (IntPtr)RtIcon);
            if (hIconRes == IntPtr.Zero)
            {
                return null;
            }
            byte[] bits = ReadResourceBytes(hMod, hIconRes);
            if (bits == null)
            {
                return null;
            }
            IntPtr hIcon = CreateIconFromResourceEx(bits, (uint)bits.Length, true, 0x00030000, size, size, 0);
            if (hIcon == IntPtr.Zero)
            {
                return null;
            }
            try
            {
                return (Icon)Icon.FromHandle(hIcon).Clone();
            }
            finally
            {
                DestroyIcon(hIcon);
            }
        }
        finally
        {
            FreeLibrary(hMod);
        }
    }

    public MainForm()
    {
        this.toolRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "ArcIcons");
        this.ids = new string[] { "arc", "arc-symbolic", "neutral-brown", "neutral-grey", "dark-grey" };
        this.labels = new string[] { "ARC", "ARC Symbolic", "Arc Neutral Brown", "Arc Neutral Grey", "Arc Dark Grey" };
        this.themeDirs = new string[] { "Windhawk Resources", "ARC Symbolic\\Windhawk Resources", "Arc Neutral Brown\\Windhawk Resources", "Arc Neutral Grey\\Windhawk Resources", "Arc Dark Grey\\Windhawk Resources" };
        BuildUi();
        PreselectInstalledVariant();
        RefreshStatus();
        RefreshPreview();
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        // The form has autoscaled by now; measure once from its real width.
        this.uiScale = 0F;
        ApplyLayout();
    }

    // The window chrome X and Esc close the app: there is no Exit button in the
    // action row, so Escape has to work from anywhere in the form.
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape)
        {
            this.Close();
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    // The dropdown opens on what is actually installed, never a hardcoded
    // first item. Read-only: the same manifest StatusText reads.
    private void PreselectInstalledVariant()
    {
        int idx = 0;
        for (int i = 0; i < this.ids.Length; i++)
        {
            if (string.Equals(this.ids[i], "dark-grey", StringComparison.OrdinalIgnoreCase))
            {
                idx = i;
                break;
            }
        }
        string vid = Program.InstalledVariantId(this.toolRoot);
        if (!string.IsNullOrEmpty(vid))
        {
            for (int i = 0; i < this.ids.Length; i++)
            {
                if (string.Equals(this.ids[i], vid, StringComparison.OrdinalIgnoreCase))
                {
                    idx = i;
                    break;
                }
            }
        }
        this.variantBox.SelectedIndex = idx;
    }

    private void BuildUi()
    {
        this.Text = "ArcInstaller";
        this.FormBorderStyle = FormBorderStyle.FixedSingle;
        this.MaximizeBox = false;
        this.StartPosition = FormStartPosition.CenterScreen;
        // DPI scaling: the 96 dpi design below is the baseline, so 150/200%
        // scales every control instead of clipping the action band.
        this.AutoScaleDimensions = new SizeF(96F, 96F);
        this.AutoScaleMode = AutoScaleMode.Dpi;
        this.ClientSize = new Size(DesignWidth, 188);
        this.BackColor = Bg;
        this.ForeColor = Fg;
        try
        {
            Icon ic = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            if (ic != null)
            {
                this.Icon = ic;
            }
        }
        catch
        {
        }

        // Identity: the variant glyph at a size a person can actually judge,
        // with its variant name under it. The name is a caption, not a control.
        this.previewBox = new PictureBox();
        this.previewBox.Location = new Point(16, 16);
        this.previewBox.Size = new Size(72, 72);
        this.previewBox.SizeMode = PictureBoxSizeMode.Zoom;
        this.previewBox.BackColor = PanelBg;
        this.previewBox.BorderStyle = BorderStyle.FixedSingle;
        this.previewBox.TabStop = false;
        this.Controls.Add(this.previewBox);

        this.variantCaption = new Label();
        this.variantCaption.Font = new Font("Segoe UI", 7.5F);
        this.variantCaption.ForeColor = Sub;
        this.variantCaption.BackColor = Bg;
        this.variantCaption.TextAlign = ContentAlignment.MiddleCenter;
        this.variantCaption.AutoEllipsis = true;
        this.variantCaption.TabStop = false;
        this.Controls.Add(this.variantCaption);

        this.variantLabel = new Label();
        this.variantLabel.Text = "Theme variant";
        this.variantLabel.ForeColor = Sub;
        this.variantLabel.BackColor = Bg;
        this.variantLabel.TabStop = false;
        this.Controls.Add(this.variantLabel);

        this.variantBox = new ComboBox();
        this.variantBox.DropDownStyle = ComboBoxStyle.DropDownList;
        this.variantBox.BackColor = PanelBg;
        this.variantBox.ForeColor = Fg;
        this.variantBox.FlatStyle = FlatStyle.Flat;
        for (int i = 0; i < this.labels.Length; i++)
        {
            this.variantBox.Items.Add(this.labels[i]);
        }
        this.variantBox.SelectedIndexChanged += new EventHandler(OnVariantChanged);
        this.Controls.Add(this.variantBox);

        // State line 1: a dot plus a word. The colour restates the word; it
        // never carries the meaning alone.
        this.stateDot = new Label();
        this.stateDot.Text = "";
        this.stateDot.BackColor = Bg;
        this.stateDot.TabStop = false;
        this.stateDot.Paint += new PaintEventHandler(PaintStateDot);
        this.Controls.Add(this.stateDot);

        this.stateLine1 = new Label();
        this.stateLine1.Text = "Not installed";
        this.stateLine1.ForeColor = Fg;
        this.stateLine1.BackColor = Bg;
        this.stateLine1.AutoEllipsis = true;
        this.stateLine1.TabStop = false;
        this.Controls.Add(this.stateLine1);

        // State line 2: the last result. The line exists before anything runs,
        // and it never claims OK without a real exit 0.
        this.stateLine2 = new Label();
        this.stateLine2.Text = "Last result: \u2014";
        this.stateLine2.ForeColor = Sub;
        this.stateLine2.BackColor = Bg;
        this.stateLine2.AutoEllipsis = true;
        this.stateLine2.TabStop = false;
        this.Controls.Add(this.stateLine2);

        // Failure bar: red, inline, above the action band. Hidden until an
        // action actually fails, so it can never be missed or mistaken for OK.
        this.failureBar = new Panel();
        this.failureBar.BackColor = DangerBar;
        this.failureBar.Visible = false;
        this.failLabel = new Label();
        this.failLabel.Text = "";
        this.failLabel.ForeColor = Danger;
        this.failLabel.BackColor = DangerBar;
        this.failLabel.AutoEllipsis = true;
        this.failLabel.TabStop = false;
        this.failureBar.Controls.Add(this.failLabel);
        this.showDetailsLink = new LinkLabel();
        this.showDetailsLink.Text = "Show details";
        this.showDetailsLink.LinkColor = Danger;
        this.showDetailsLink.ActiveLinkColor = Color.White;
        this.showDetailsLink.VisitedLinkColor = Danger;
        this.showDetailsLink.LinkBehavior = LinkBehavior.HoverUnderline;
        this.showDetailsLink.BackColor = DangerBar;
        this.showDetailsLink.TextAlign = ContentAlignment.MiddleRight;
        this.showDetailsLink.TabStop = false;
        this.showDetailsLink.LinkClicked += new LinkLabelLinkClickedEventHandler(OnShowDetails);
        this.failureBar.Controls.Add(this.showDetailsLink);
        this.Controls.Add(this.failureBar);

        // Exactly one primary: Install theme absorbs Apply and Install all.
        this.installBtn = MakeBtn("Install theme", Accent, Color.White, true);
        this.installBtn.Click += new EventHandler(OnInstallClick);
        this.statusBtn = MakeBtn("Check status", PanelBg, Fg, false);
        this.statusBtn.Click += new EventHandler(OnStatusClick);
        this.moreBtn = MakeBtn("More \u25BE", PanelBg, Fg, false);
        this.moreBtn.Click += new EventHandler(OnMoreClick);

        // The log is a strip, shut by default - no permanent empty void.
        this.detailsBtn = new Button();
        this.detailsBtn.Text = "Details \u25B8";
        this.detailsBtn.FlatStyle = FlatStyle.Flat;
        this.detailsBtn.BackColor = Bg;
        this.detailsBtn.ForeColor = Sub;
        this.detailsBtn.FlatAppearance.BorderSize = 0;
        this.detailsBtn.TextAlign = ContentAlignment.MiddleRight;
        this.detailsBtn.Cursor = Cursors.Hand;
        this.detailsBtn.Click += new EventHandler(OnToggleDetails);
        this.Controls.Add(this.detailsBtn);

        this.outputBox = new TextBox();
        this.outputBox.Multiline = true;
        this.outputBox.ReadOnly = true;
        this.outputBox.ScrollBars = ScrollBars.Both;
        this.outputBox.WordWrap = false;
        this.outputBox.Font = new Font("Consolas", 9);
        this.outputBox.BackColor = EditBg;
        this.outputBox.ForeColor = Color.FromArgb(0xD4, 0xD4, 0xD4);
        this.outputBox.BorderStyle = BorderStyle.FixedSingle;
        this.outputBox.Visible = false;
        this.Controls.Add(this.outputBox);

        // Overflow: destructive and occasional verbs live behind one menu, so
        // they cannot compete with Install theme for the same click.
        this.moreMenu = new ContextMenuStrip();
        this.moreMenu.BackColor = PanelBg;
        this.moreMenu.ForeColor = Fg;
        ToolStripMenuItem remove = new ToolStripMenuItem("Remove theme\u2026");
        remove.ForeColor = Danger;
        remove.Click += new EventHandler(OnRemoveTheme);
        ToolStripMenuItem repair = new ToolStripMenuItem("Repair\u2026");
        repair.ForeColor = Fg;
        repair.Click += new EventHandler(OnRepairClick);
        ToolStripMenuItem logs = new ToolStripMenuItem("Open logs folder");
        logs.ForeColor = Fg;
        logs.Click += new EventHandler(OnOpenLogs);
        this.moreMenu.Items.Add(remove);
        this.moreMenu.Items.Add(new ToolStripSeparator());
        this.moreMenu.Items.Add(repair);
        this.moreMenu.Items.Add(logs);
        this.moreBtn.ContextMenuStrip = this.moreMenu;

        // Tab order is the reading order of the card.
        this.variantBox.TabIndex = 0;
        this.installBtn.TabIndex = 1;
        this.statusBtn.TabIndex = 2;
        this.moreBtn.TabIndex = 3;
        this.detailsBtn.TabIndex = 4;
        this.outputBox.TabIndex = 5;
        this.AcceptButton = this.installBtn;

        this.uiScale = 1F;
        ApplyLayout();
    }

    private Button MakeBtn(string text, Color back, Color fore, bool bold)
    {
        Button b = new Button();
        b.Text = text;
        b.FlatStyle = FlatStyle.Flat;
        b.BackColor = back;
        b.ForeColor = fore;
        b.FlatAppearance.BorderColor = bold ? Accent : Color.FromArgb(0x3C, 0x3C, 0x3C);
        if (bold)
        {
            b.Font = new Font("Segoe UI", 9F, FontStyle.Bold);
        }
        this.Controls.Add(b);
        return b;
    }

    private static int S(int v, float s)
    {
        return (int)Math.Round((double)v * (double)s);
    }

    private static Rectangle R(int x, int y, int w, int h, float s)
    {
        return new Rectangle(S(x, s), S(y, s), S(w, s), S(h, s));
    }

    // One layout routine owns every position and the window height, so the
    // failure bar appearing moves the action band down instead of overlapping
    // the state lines. Expanded height is the log strip, never a second row.
    private void ApplyLayout()
    {
        if (this.uiScale <= 0F)
        {
            float w = (float)this.ClientSize.Width / (float)DesignWidth;
            if (w < 0.5F || w > 4F)
            {
                w = 1F;
            }
            this.uiScale = w;
        }
        float s = this.uiScale;
        int bandY = this.failureVisible ? 150 : 112;
        int detailsY = bandY + 40;
        int logY = detailsY + 28;

        this.previewBox.Bounds = R(16, 16, 72, 72, s);
        this.variantCaption.Bounds = R(8, 92, 88, 16, s);
        this.variantLabel.Bounds = R(112, 16, 200, 16, s);
        this.variantBox.Bounds = R(112, 34, 280, 24, s);
        this.stateDot.Bounds = R(112, 67, 10, 10, s);
        this.stateLine1.Bounds = R(128, 62, 416, 18, s);
        this.stateLine2.Bounds = R(112, 84, 432, 18, s);

        this.failureBar.Bounds = R(16, 112, 528, 30, s);
        this.failLabel.Bounds = R(10, 7, 392, 16, s);
        this.showDetailsLink.Bounds = R(406, 3, 112, 24, s);
        this.failureBar.Visible = this.failureVisible;

        this.installBtn.Bounds = R(16, bandY, 200, 32, s);
        this.statusBtn.Bounds = R(224, bandY, 112, 32, s);
        this.moreBtn.Bounds = R(432, bandY, 112, 32, s);
        this.detailsBtn.Bounds = R(454, detailsY, 90, 20, s);
        this.detailsBtn.Text = this.detailsOpen ? "Details \u25BE" : "Details \u25B8";
        this.outputBox.Bounds = R(16, logY, 528, 130, s);
        this.outputBox.Visible = this.detailsOpen;

        int height = detailsY + (this.detailsOpen ? 174 : 36);
        this.ClientSize = new Size(S(DesignWidth, s), S(height, s));
    }

    private void PaintStateDot(object sender, PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        Rectangle r = this.stateDot.ClientRectangle;
        using (SolidBrush b = new SolidBrush(this.dotColor))
        {
            e.Graphics.FillEllipse(b, 0.5f, 0.5f, (float)r.Width - 1.5f, (float)r.Height - 1.5f);
        }
    }

    private void OnShowDetails(object s, LinkLabelLinkClickedEventArgs e)
    {
        this.detailsOpen = true;
        ApplyLayout();
    }

    private void OnToggleDetails(object s, EventArgs e)
    {
        this.detailsOpen = !this.detailsOpen;
        ApplyLayout();
    }

    private void OnVariantChanged(object s, EventArgs e)
    {
        RefreshPreview();
    }

    private void RefreshPreview()
    {
        try
        {
            if (this.previewBox == null)
            {
                return;
            }
            if (this.previewBox.Image != null)
            {
                Image old = this.previewBox.Image;
                this.previewBox.Image = null;
                old.Dispose();
            }
            int i = this.variantBox.SelectedIndex;
            if (i < 0 || i >= this.themeDirs.Length)
            {
                i = 0;
            }
            this.variantCaption.Text = this.labels[i];
            string dll = Path.Combine(this.toolRoot, "theme");
            dll = Path.Combine(dll, this.themeDirs[i]);
            dll = Path.Combine(dll, "imageres.dll");
            if (!File.Exists(dll))
            {
                return;
            }
            Icon ico = LoadGroupIconById(dll, FolderGlyphGroupId, this.previewBox.Height);
            if (ico == null)
            {
                return;
            }
            try
            {
                Bitmap bmp = ico.ToBitmap();
                ico.Dispose();
                this.previewBox.Image = bmp;
            }
            catch
            {
                try { ico.Dispose(); }
                catch { }
            }
        }
        catch
        {
        }
    }

    private enum Health
    {
        Healthy,
        NotInstalled,
        Unknown,
        Attention
    }

    // Health is read from the same manifest StatusText reads. "Drift" here is
    // the loudest cheap signal available without running an action: the
    // manifest claims a variant whose theme payload is no longer on disk, or
    // the manifest itself cannot be read. Both mean the card must not say OK.
    private Health ComputeHealth(out string variantLabel)
    {
        variantLabel = "";
        try
        {
            string man = Path.Combine(this.toolRoot, "installed-manifest.json");
            if (!File.Exists(man))
            {
                return Health.NotInstalled;
            }
            string status = Program.StatusText(this.toolRoot);
            if (status != null && status.IndexOf("unreadable", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return Health.Attention;
            }
            string vid = Program.InstalledVariantId(this.toolRoot);
            if (string.IsNullOrEmpty(vid))
            {
                return Health.Unknown;
            }
            int i = IndexOfId(vid);
            if (i < 0)
            {
                return Health.Unknown;
            }
            variantLabel = this.labels[i];
            string dll = Path.Combine(this.toolRoot, "theme");
            dll = Path.Combine(dll, this.themeDirs[i]);
            dll = Path.Combine(dll, "imageres.dll");
            if (!File.Exists(dll))
            {
                return Health.Attention;
            }
            return Health.Healthy;
        }
        catch
        {
            return Health.Attention;
        }
    }

    private int IndexOfId(string id)
    {
        for (int i = 0; i < this.ids.Length; i++)
        {
            if (string.Equals(this.ids[i], id, StringComparison.OrdinalIgnoreCase))
            {
                return i;
            }
        }
        return -1;
    }

    private void RefreshStatus()
    {
        string variantLabel;
        Health h = ComputeHealth(out variantLabel);
        switch (h)
        {
            case Health.Healthy:
                this.dotColor = Healthy;
                this.stateLine1.Text = "Installed: " + variantLabel + " \u2014 healthy";
                this.stateLine1.ForeColor = Fg;
                break;
            case Health.NotInstalled:
                this.dotColor = Sub;
                this.stateLine1.Text = "Not installed";
                this.stateLine1.ForeColor = Fg;
                break;
            case Health.Unknown:
                this.dotColor = Unknown;
                this.stateLine1.Text = "Installed: ? \u2014 status unknown";
                this.stateLine1.ForeColor = Fg;
                break;
            default:
                this.dotColor = Danger;
                this.stateLine1.Text = "Installed: " +
                    (string.IsNullOrEmpty(variantLabel) ? "?" : variantLabel) +
                    " \u2014 needs attention";
                this.stateLine1.ForeColor = Fg;
                break;
        }
        this.stateDot.Invalidate();
    }

    private string CurrentVariantId()
    {
        int i = this.variantBox.SelectedIndex;
        if (i < 0 || i >= this.ids.Length)
        {
            i = 0;
        }
        return this.ids[i];
    }

    private void SetBusy(bool busy)
    {
        bool en = !busy;
        this.installBtn.Enabled = en;
        this.statusBtn.Enabled = en;
        this.moreBtn.Enabled = en;
        this.variantBox.Enabled = en;
    }

    private void AppendLine(string line)
    {
        if (this.outputBox.InvokeRequired)
        {
            this.outputBox.BeginInvoke((MethodInvoker)delegate
            {
                AppendLine(line);
            });
            return;
        }
        if (line == null)
        {
            return;
        }
        this.outputBox.AppendText(line + "\r\n");
    }

    private void ClearFailure()
    {
        this.failureVisible = false;
        this.failLabel.Text = "";
    }

    private void ShowLastResultOk(string action)
    {
        this.stateLine2.ForeColor = Sub;
        this.stateLine2.Text = "Last result: OK " + action + " " + DateTime.Now.ToString("HH:mm");
    }

    // A failure is never silent: red line 2, the inline red bar with the first
    // error line, and the log strip opened so the whole story is one click away.
    private void ShowFailure(string firstError, string action, string exitText)
    {
        this.failureVisible = true;
        this.detailsOpen = true;
        this.failLabel.Text = string.IsNullOrEmpty(firstError)
            ? "The action failed. See details for the full output."
            : firstError;
        this.stateLine2.ForeColor = Danger;
        this.stateLine2.Text = "Last result: FAILED " + action + " " + exitText;
        ApplyLayout();
    }

    private void OnInstallClick(object s, EventArgs e) { RunAction("install"); }
    private void OnStatusClick(object s, EventArgs e) { RunAction("status"); }
    private void OnRepairClick(object s, EventArgs e) { RunAction("repair"); }

    private void OnMoreClick(object s, EventArgs e)
    {
        this.moreMenu.Show(this.moreBtn, new Point(0, this.moreBtn.Height));
    }

    // Destructive verbs confirm in plain words: what comes back, what goes.
    private void OnRemoveTheme(object s, EventArgs e)
    {
        DialogResult r = MessageBox.Show(
            this,
            "Remove the Arc icon theme?\n\nWindows icons return to their stock appearance and the installed theme is removed from this PC.",
            "Remove theme",
            MessageBoxButtons.OKCancel,
            MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button2);
        if (r == DialogResult.OK)
        {
            RunAction("uninstall");
        }
    }

    private void OnOpenLogs(object s, EventArgs e)
    {
        try
        {
            string logs = Path.Combine(this.toolRoot, "logs");
            if (!Directory.Exists(logs))
            {
                MessageBox.Show(this, "No logs folder yet. Run an action first.", "ArcInstaller",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            Process.Start("explorer.exe", "\"" + logs + "\"");
        }
        catch (Exception ex)
        {
            ShowFailure("Could not open the logs folder: " + ex.Message, "logs", "(could not open)");
        }
    }

    private void RunAction(string action)
    {
        string variantId = CurrentVariantId();
        ClearFailure();
        this.sawFailureSignal = false;
        this.firstErrorLine = null;
        SetBusy(true);
        // Running an action opens the log, same as before; the difference is
        // that a failure also must, even if the strip was closed.
        this.detailsOpen = true;
        ApplyLayout();
        AppendLine("== " + action + " variant=" + variantId + " ==");
        try
        {
            string controller = Path.Combine(this.toolRoot, "ARC-Icons.ps1");
            string arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + controller + "\" -Action " + action + " -Variant " + variantId + " -Yes";
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = PowerShellForForm();
            psi.Arguments = arguments;
            psi.UseShellExecute = false;
            psi.EnvironmentVariables["PSModulePath"] = Program.WinPsModulePath();
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
            Process proc = new Process();
            proc.StartInfo = psi;
            proc.EnableRaisingEvents = true;
            proc.OutputDataReceived += new DataReceivedEventHandler(OnOut);
            proc.ErrorDataReceived += new DataReceivedEventHandler(OnErr);
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            System.Threading.Thread waiter = new System.Threading.Thread(new System.Threading.ParameterizedThreadStart(WaitProc));
            waiter.IsBackground = true;
            waiter.Start(new object[] { proc, action });
        }
        catch (Exception ex)
        {
            AppendLine("FAILED " + ex.Message);
            ShowFailure(ex.Message, action, "(could not start)");
            SetBusy(false);
        }
    }

    private string PowerShellForForm()
    {
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (string.IsNullOrEmpty(sysRoot))
        {
            sysRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        }
        string candidate = Path.Combine(sysRoot, "System32");
        candidate = Path.Combine(candidate, "WindowsPowerShell");
        candidate = Path.Combine(candidate, "v1.0");
        candidate = Path.Combine(candidate, "powershell.exe");
        if (File.Exists(candidate))
        {
            return candidate;
        }
        return "powershell.exe";
    }

    private void OnOut(object s, DataReceivedEventArgs e)
    {
        if (e.Data == null)
        {
            return;
        }
        // A script that printed FAIL or FAILED has failed even if it still
        // exited 0 (Show-Status runs verify without propagating its code).
        string upper = e.Data.ToUpperInvariant();
        if (upper.IndexOf("FAILED", StringComparison.Ordinal) >= 0 ||
            upper.IndexOf("FAIL", StringComparison.Ordinal) >= 0)
        {
            this.sawFailureSignal = true;
            if (this.firstErrorLine == null)
            {
                this.firstErrorLine = e.Data.Trim();
            }
        }
        AppendLine(e.Data);
    }

    private void OnErr(object s, DataReceivedEventArgs e)
    {
        if (e.Data == null)
        {
            return;
        }
        if (this.firstErrorLine == null)
        {
            this.firstErrorLine = e.Data.Trim();
        }
        AppendLine(e.Data);
    }

    private void WaitProc(object state)
    {
        object[] arr = (object[])state;
        Process proc = (Process)arr[0];
        string action = (string)arr[1];
        // The parameterless overload also waits for the redirected streams to
        // reach EOF, so the failure token scan above is complete here.
        proc.WaitForExit();
        int code = proc.ExitCode;
        try { proc.Close(); }
        catch { }
        if (this.IsDisposed)
        {
            return;
        }
        try
        {
            this.BeginInvoke((MethodInvoker)delegate
            {
                if (code == 0 && !this.sawFailureSignal)
                {
                    AppendLine("OK " + action);
                    ShowLastResultOk(action);
                }
                else
                {
                    string exitText = code == 0 ? "(reported a failure)" : "(exit " + code.ToString() + ")";
                    AppendLine("FAILED " + action + " " + exitText);
                    ShowFailure(this.firstErrorLine, action, exitText);
                }
                RefreshStatus();
                SetBusy(false);
            });
        }
        catch (InvalidOperationException)
        {
        }
    }
}

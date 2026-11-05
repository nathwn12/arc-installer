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

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--selftest")
        {
            return DoSelfTest();
        }
        if (args.Length > 0 && args[0] == "--cli")
        {
            EnsureToolTree();
            return DoCli(args);
        }
        EnsureToolTree();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        MainForm f = new MainForm();
        Application.Run(f);
        return 0;
    }

    static string GetToolRoot()
    {
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

    static void EnsureToolTree()
    {
        string root = GetToolRoot();
        Directory.CreateDirectory(root);
        string fullRoot = Path.GetFullPath(root);
        if (!fullRoot.EndsWith(Path.DirectorySeparatorChar.ToString()))
        {
            fullRoot = fullRoot + Path.DirectorySeparatorChar;
        }
        Assembly asm = Assembly.GetExecutingAssembly();
        using (Stream rs = asm.GetManifestResourceStream("payload.zip"))
        {
            if (rs == null)
            {
                throw new InvalidOperationException("embedded payload.zip missing");
            }
            using (ZipArchive z = new ZipArchive(rs, ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry e in z.Entries)
                {
                    if (string.IsNullOrEmpty(e.Name))
                    {
                        continue;
                    }
                    string rel = e.FullName.Replace('/', Path.DirectorySeparatorChar);
                    string dest = Path.Combine(root, rel);
                    string fullDest = Path.GetFullPath(dest);
                    if (!fullDest.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }
                    bool need = true;
                    if (File.Exists(fullDest))
                    {
                        string want;
                        using (Stream es = e.Open())
                        {
                            want = HashStream(es);
                        }
                        string have = HashFile(fullDest);
                        if (string.Equals(want, have, StringComparison.OrdinalIgnoreCase))
                        {
                            need = false;
                        }
                    }
                    if (need)
                    {
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
            Directory.CreateDirectory(dir);
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
    private ComboBox variantBox;
    private Label statusLabel;
    private TextBox outputBox;
    private Button applyBtn;
    private Button repairBtn;
    private Button revertBtn;
    private Button refreshBtn;
    private Button exitBtn;
    private string toolRoot;
    private string[] ids;
    private string[] labels;
    private string[] themeDirs;
    private PictureBox previewBox;
    private Button detailsBtn;
    private bool detailsOpen;
    // Fixed-size card: collapsed shows the controls; expanded adds the log strip.
    private const int CollapsedHeight = 198;
    private const int ExpandedHeight = 336;

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
        this.ids = new string[] { "arc", "neutral-brown", "neutral-grey", "dark-grey" };
        this.labels = new string[] { "ARC", "Arc Neutral Brown", "Arc Neutral Grey", "Arc Dark Grey" };
        this.themeDirs = new string[] { "Windhawk Resources", "Arc Neutral Brown\\Windhawk Resources", "Arc Neutral Grey\\Windhawk Resources", "Arc Dark Grey\\Windhawk Resources" };
        BuildUi();
        PreselectInstalledVariant();
        RefreshStatus();
        RefreshPreview();
    }

    // The dropdown opens on what is actually installed, never a hardcoded
    // first item. Read-only: the same manifest StatusText reads.
    private void PreselectInstalledVariant()
    {
        int idx = 3;
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
        Color bg = Color.FromArgb(0x1E, 0x1E, 0x1E);
        Color fg = Color.FromArgb(0xE8, 0xE8, 0xE8);
        Color panel = Color.FromArgb(0x2D, 0x2D, 0x2D);
        Color edit = Color.FromArgb(0x25, 0x25, 0x26);
        Color accent = Color.FromArgb(0x2F, 0x6F, 0x9E);
        Color sub = Color.FromArgb(0xA8, 0xA8, 0xA8);
        this.Text = "ArcInstaller";
        this.FormBorderStyle = FormBorderStyle.FixedSingle;
        this.MaximizeBox = false;
        this.StartPosition = FormStartPosition.CenterScreen;
        this.ClientSize = new Size(560, CollapsedHeight);
        this.BackColor = bg;
        this.ForeColor = fg;
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

        // Left: the variant glyph at a size a person can actually judge.
        this.previewBox = new PictureBox();
        this.previewBox.Location = new Point(16, 18);
        this.previewBox.Size = new Size(72, 72);
        this.previewBox.SizeMode = PictureBoxSizeMode.Zoom;
        this.previewBox.BackColor = panel;
        this.previewBox.BorderStyle = BorderStyle.FixedSingle;
        this.Controls.Add(this.previewBox);

        Label pick = new Label();
        pick.Text = "Variant";
        pick.Location = new Point(104, 18);
        pick.Size = new Size(120, 18);
        pick.BackColor = bg;
        pick.ForeColor = sub;
        this.Controls.Add(pick);

        this.variantBox = new ComboBox();
        this.variantBox.DropDownStyle = ComboBoxStyle.DropDownList;
        this.variantBox.Location = new Point(104, 38);
        this.variantBox.Size = new Size(280, 22);
        this.variantBox.BackColor = panel;
        this.variantBox.ForeColor = fg;
        this.variantBox.FlatStyle = FlatStyle.Flat;
        for (int i = 0; i < this.labels.Length; i++)
        {
            this.variantBox.Items.Add(this.labels[i]);
        }
        this.variantBox.SelectedIndexChanged += new EventHandler(OnVariantChanged);
        this.Controls.Add(this.variantBox);

        this.statusLabel = new Label();
        this.statusLabel.Location = new Point(104, 68);
        this.statusLabel.Size = new Size(440, 20);
        this.statusLabel.AutoEllipsis = true;
        this.statusLabel.BackColor = bg;
        this.statusLabel.ForeColor = fg;
        this.Controls.Add(this.statusLabel);

        // Apply is the action almost every open wants, so it reads primary;
        // the rest are secondary. Behavior is unchanged.
        int top = 112;
        this.applyBtn = MakeBtn("Apply", 16, top, accent, Color.White, true);
        this.applyBtn.Click += new EventHandler(OnApply);
        this.repairBtn = MakeBtn("Repair", 128, top, panel, fg, false);
        this.repairBtn.Click += new EventHandler(OnRepair);
        this.revertBtn = MakeBtn("Revert", 224, top, panel, fg, false);
        this.revertBtn.Click += new EventHandler(OnRevert);
        this.refreshBtn = MakeBtn("Refresh", 320, top, panel, fg, false);
        this.refreshBtn.Click += new EventHandler(OnRefresh);
        this.exitBtn = MakeBtn("Exit", 456, top, panel, fg, false);
        this.exitBtn.Click += new EventHandler(OnExit);

        // The log is a strip, shut by default - no permanent empty void.
        this.detailsBtn = new Button();
        this.detailsBtn.Text = "Details \u25B8";
        this.detailsBtn.Location = new Point(16, 156);
        this.detailsBtn.Size = new Size(96, 26);
        this.detailsBtn.FlatStyle = FlatStyle.Flat;
        this.detailsBtn.BackColor = panel;
        this.detailsBtn.ForeColor = fg;
        this.detailsBtn.FlatAppearance.BorderColor = Color.FromArgb(0x3C, 0x3C, 0x3C);
        this.detailsBtn.Click += new EventHandler(OnToggleDetails);
        this.Controls.Add(this.detailsBtn);

        this.outputBox = new TextBox();
        this.outputBox.Multiline = true;
        this.outputBox.ReadOnly = true;
        this.outputBox.ScrollBars = ScrollBars.Both;
        this.outputBox.WordWrap = false;
        this.outputBox.Font = new Font("Consolas", 9);
        this.outputBox.Location = new Point(16, 190);
        this.outputBox.Size = new Size(528, 130);
        this.outputBox.BackColor = edit;
        this.outputBox.ForeColor = Color.FromArgb(0xD4, 0xD4, 0xD4);
        this.outputBox.BorderStyle = BorderStyle.FixedSingle;
        this.outputBox.Visible = false;
        this.Controls.Add(this.outputBox);
    }

    private Button MakeBtn(string text, int x, int y, Color back, Color fore, bool primary)
    {
        Button b = new Button();
        b.Text = text;
        b.Location = new Point(x, y);
        b.Size = new Size(88, 28);
        b.FlatStyle = FlatStyle.Flat;
        b.BackColor = back;
        b.ForeColor = fore;
        b.FlatAppearance.BorderColor = Color.FromArgb(0x3C, 0x3C, 0x3C);
        if (primary)
        {
            b.Font = new Font(b.Font, FontStyle.Bold);
        }
        this.Controls.Add(b);
        return b;
    }

    private void OnToggleDetails(object s, EventArgs e)
    {
        this.detailsOpen = !this.detailsOpen;
        this.outputBox.Visible = this.detailsOpen;
        this.detailsBtn.Text = this.detailsOpen ? "Details \u25BE" : "Details \u25B8";
        this.ClientSize = new Size(this.ClientSize.Width, this.detailsOpen ? ExpandedHeight : CollapsedHeight);
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

    private void RefreshStatus()
    {
        string s = Program.StatusText(this.toolRoot);
        this.statusLabel.Text = s;
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
        this.applyBtn.Enabled = en;
        this.repairBtn.Enabled = en;
        this.revertBtn.Enabled = en;
        this.refreshBtn.Enabled = en;
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

    private void OnApply(object s, EventArgs e) { RunAction("apply"); }
    private void OnRepair(object s, EventArgs e) { RunAction("repair"); }
    private void OnRevert(object s, EventArgs e) { RunAction("revert"); }
    private void OnRefresh(object s, EventArgs e) { RunAction("refresh"); }
    private void OnExit(object s, EventArgs e) { this.Close(); }

    private void RunAction(string action)
    {
        string variantId = CurrentVariantId();
        SetBusy(true);
        if (!this.detailsOpen)
        {
            OnToggleDetails(null, EventArgs.Empty);
        }
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
        if (e.Data != null)
        {
            AppendLine(e.Data);
        }
    }

    private void OnErr(object s, DataReceivedEventArgs e)
    {
        if (e.Data != null)
        {
            AppendLine(e.Data);
        }
    }

    private void WaitProc(object state)
    {
        object[] arr = (object[])state;
        Process proc = (Process)arr[0];
        string action = (string)arr[1];
        proc.WaitForExit();
        int code = proc.ExitCode;
        try { proc.Close(); }
        catch { }
        this.BeginInvoke((MethodInvoker)delegate
        {
            if (code == 0)
            {
                AppendLine("OK " + action);
            }
            else
            {
                AppendLine("FAILED (exit " + code.ToString() + ")");
            }
            RefreshStatus();
            SetBusy(false);
        });
    }
}

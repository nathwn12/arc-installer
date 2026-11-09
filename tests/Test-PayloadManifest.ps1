<#
.SYNOPSIS
  Prove the embedded-payload guard: every launch verifies payload.zip against
  payload-manifest.json before writing, and a mismatch or a zip bomb writes nothing.

.DESCRIPTION
  Runs the built dist\ArcInstaller.exe (and tiny fixture exes compiled from the
  same src\ArcInstaller.cs with the same in-box csc line as build.ps1) against
  temp-only tool roots. Nothing is written to %ProgramData% and no host file is
  touched.

    (a) healthy payload: --extract exits 0, every extracted file matches the
        manifest, and a corrupted file is rewritten on the next launch;
    (b) tampered fixtures, each exiting non-zero with nothing written:
          - a manifest row whose sha256 does not match the archive bytes,
          - a manifest row with no archive entry,
          - an archive entry with no manifest row,
          - an entry that escapes the install root ('../escape.txt'),
        through both --extract and the no-argument (GUI) launch, plus --cli;
    (c) a payload whose declared size passes the zip-bomb cap: exits non-zero;
        a junction tool root and a hardlinked install target are refused;
    (d) dist --selftest still exits 0 and verifies every file.

  The tampered route is a fixture zip run through the real launch path, which is
  the honest proof: the guard is the shipped code, only the payload differs.

  Run from an elevated Windows PowerShell 5.1 shell (app.manifest is
  requireAdministrator): powershell -NoProfile -File tests\Test-PayloadManifest.ps1
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repo        = Split-Path -Parent $PSScriptRoot
$exe         = Join-Path $repo 'dist\ArcInstaller.exe'
$src         = Join-Path $repo 'src\ArcInstaller.cs'
$appManifest = Join-Path $repo 'src\app.manifest'
$csc         = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

foreach ($p in @($exe, $src, $appManifest, $csc)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "missing $p - run build.ps1 first (it needs theme\; see AGENTS.md)"
    }
}

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'run from an elevated shell: the exe manifest is requireAdministrator and Start-Process would fail with 740'
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('arc-payload-manifest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

$script:checks = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:checks++
    if (-not $Condition) { throw "FAIL $Message" }
}

function Assert-Match([string]$Text, [string]$Pattern, [string]$Message) {
    $script:checks++
    if ($Text -notmatch $Pattern) { throw "FAIL $Message (got: $Text)" }
}

function Get-Sha256Hex([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-TextSha256([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($Text))
        return (($bytes | ForEach-Object { $_.ToString('X2') }) -join '')
    }
    finally { $sha.Dispose() }
}

# One launch, one temp tool root, one captured result. The env var is the test
# seam inside ArcInstaller.cs; the payload is still verified either way.
function Invoke-Installer {
    param(
        [string]$ExePath,
        [string[]]$Arguments,
        [string]$ToolRoot
    )
    # Start-Process -PassThru reports an empty ExitCode for a winexe in
    # Windows PowerShell 5.1 unless -Wait is used, and -Wait cannot time out.
    # A raw Process gives both the real exit code and a watchdog.
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.EnvironmentVariables['ARCINSTALLER_TOOL_ROOT'] = $ToolRoot
    $proc = [Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(180000)) {
        try { $proc.Kill() } catch { }
        throw "timeout after 180s: $ExePath $($Arguments -join ' ')"
    }
    $proc.WaitForExit()
    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $outTask.Result
        StdErr   = $errTask.Result
    }
}

function Get-TreeFileCount([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return 0 }
    @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue).Count
}

# Compile a fixture exe from the shipped source and a chosen payload. The csc
# line is build.ps1's, minus the icon; only the embedded zip differs.
function New-FixtureExe {
    param(
        [string]$Name,
        [hashtable]$Files,
        [object[]]$Rows
    )
    $dir = Join-Path $work $Name
    $filesDir = Join-Path $dir 'files'
    New-Item -ItemType Directory -Force -Path $filesDir | Out-Null
    foreach ($key in $Files.Keys) {
        $dest = Join-Path $filesDir $key
        $parent = Split-Path -Parent $dest
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        [IO.File]::WriteAllText($dest, [string]$Files[$key], (New-Object Text.UTF8Encoding($false)))
    }
    # build.ps1 writes path before sha256; new-fixture rows keep that order too.
    $manifest = [pscustomobject]@{ generated = (Get-Date).ToString('o'); files = @($Rows) }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $filesDir 'payload-manifest.json') -Encoding utf8
    $zip = Join-Path $dir 'payload.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($filesDir, $zip,
        [IO.Compression.CompressionLevel]::Optimal, $false)
    New-ExeFromZip -Name $Name -ZipPath $zip
}

# A zip whose single entry declares 705 MiB decompressed: over the 704 MiB
# (738,197,504-byte) cap, ~718 KB on disk, ~0.3 s to write. No manifest entry
# is needed because the cap is checked before the manifest is read.
function New-BombExe {
    param([string]$Name)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = Join-Path $dir 'payload.zip'
    $fs = [IO.File]::Open($zip, [IO.FileMode]::Create)
    try {
        $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $za.CreateEntry('bomb.bin', [IO.Compression.CompressionLevel]::Optimal)
            $stream = $entry.Open()
            try {
                $buffer = New-Object byte[] (1048576)
                $left = 705L * 1024 * 1024
                while ($left -gt 0) {
                    $n = [int][Math]::Min([long]$buffer.Length, $left)
                    $stream.Write($buffer, 0, $n)
                    $left -= $n
                }
            }
            finally { $stream.Dispose() }
        }
        finally { $za.Dispose() }
    }
    finally { $fs.Dispose() }
    New-ExeFromZip -Name $Name -ZipPath $zip
}

# Compile a fixture exe around an already-built payload.zip (for zips whose
# entry names ZipFile.CreateFromDirectory cannot produce, such as '../escape').
function New-ExeFromZip {
    param([string]$Name, [string]$ZipPath)
    $fixtureExe = Join-Path (Split-Path -Parent $ZipPath) ($Name + '.exe')
    & $csc /nologo /target:winexe "/out:$fixtureExe" "/win32manifest:$appManifest" `
        /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Core.dll `
        /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
        "/resource:$ZipPath,payload.zip" $src
    if ($LASTEXITCODE -ne 0) { throw "fixture compile failed for '$Name' (csc exit $LASTEXITCODE)" }
    $fixtureExe
}

$failed = $false
try {
    # ---- (a) healthy built exe extracts, verifies, repairs -----------------
    $healthyRoot = Join-Path $work 'roots\healthy'
    $r = Invoke-Installer -ExePath $exe -Arguments @('--extract') -ToolRoot $healthyRoot
    Assert-True ($r.ExitCode -eq 0) "healthy --extract exit 0 (got $($r.ExitCode), stderr: $($r.StdErr))"
    Assert-True ((Test-Path -LiteralPath (Join-Path $healthyRoot 'payload-manifest.json'))) 'healthy extract wrote payload-manifest.json'
    $manifestPath = Join-Path $healthyRoot 'payload-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $rows = @($manifest.files)
    Assert-True ($rows.Count -gt 40) "manifest rows >= 41 (got $($rows.Count))"
    $verified = 0
    foreach ($row in $rows) {
        $rel = $row.path -replace '/', '\'
        $file = Join-Path $healthyRoot $rel
        Assert-True (Test-Path -LiteralPath $file -PathType Leaf) "healthy extract present: $($row.path)"
        Assert-True ((Get-Sha256Hex $file) -eq $row.sha256) "healthy extract hash matches manifest: $($row.path)"
        $verified++
    }
    $onDisk = Get-TreeFileCount $healthyRoot
    Assert-True ($onDisk -eq ($rows.Count + 1)) "extracted file count $onDisk == manifest rows $($rows.Count) + payload-manifest.json"

    # Incremental behaviour: an unchanged tree is a no-op, a changed file is restored.
    $r = Invoke-Installer -ExePath $exe -Arguments @('--extract') -ToolRoot $healthyRoot
    Assert-True ($r.ExitCode -eq 0) "second healthy --extract exit 0 (got $($r.ExitCode))"
    $victim = Join-Path $healthyRoot 'ARC-Icons.ps1'
    $wantVictim = Get-Sha256Hex $victim
    Set-Content -LiteralPath $victim -Value 'tampered on disk' -Encoding ASCII
    $r = Invoke-Installer -ExePath $exe -Arguments @('--extract') -ToolRoot $healthyRoot
    Assert-True ($r.ExitCode -eq 0) "repair --extract exit 0 (got $($r.ExitCode), stderr: $($r.StdErr))"
    Assert-True ((Get-Sha256Hex $victim) -eq $wantVictim) 'a corrupted installed file is rewritten to the manifest bytes'
    Assert-True ((@(Get-ChildItem -LiteralPath $healthyRoot -Recurse -File -Filter '*.arc-new').Count) -eq 0) 'no .arc-new temp file left behind'
    Write-Output "OK healthy: $verified/$($rows.Count) manifest rows match on disk"

    # ---- (b) tampered payloads: non-zero exit, nothing written -------------
    $probeText = 'probe payload bytes'
    $probeHash = Get-TextSha256 $probeText

    # Control: the same fixture with a truthful row must extract, so a failure
    # below is the guard and not the fixture harness.
    $goodExe = New-FixtureExe -Name 'good' -Files @{ 'probe.txt' = $probeText } `
        -Rows @([pscustomobject]@{ path = 'probe.txt'; sha256 = $probeHash })
    $goodRoot = Join-Path $work 'roots\good'
    $r = Invoke-Installer -ExePath $goodExe -Arguments @('--extract') -ToolRoot $goodRoot
    Assert-True ($r.ExitCode -eq 0) "truthful fixture control exit 0 (got $($r.ExitCode), stderr: $($r.StdErr))"
    Assert-True ((Get-Sha256Hex (Join-Path $goodRoot 'probe.txt')) -eq $probeHash) 'truthful fixture wrote the expected probe.txt'

    # (b1) manifest row digest does not match the archive bytes.
    $badHashExe = New-FixtureExe -Name 'badhash' -Files @{ 'probe.txt' = $probeText } `
        -Rows @([pscustomobject]@{ path = 'probe.txt'; sha256 = ('0' * 64) })
    $badHashRoot = Join-Path $work 'roots\badhash'
    $r = Invoke-Installer -ExePath $badHashExe -Arguments @('--extract') -ToolRoot $badHashRoot
    Assert-True ($r.ExitCode -ne 0) "hash mismatch exits non-zero (got $($r.ExitCode))"
    Assert-True ($r.ExitCode -eq 2) "hash mismatch uses the payload-untrusted exit code 2 (got $($r.ExitCode))"
    Assert-Match $r.StdErr 'payload verification failed' 'hash mismatch names the payload gate'
    Assert-Match $r.StdErr 'probe\.txt' 'hash mismatch names the offending entry'
    Assert-Match $r.StdErr 'hashes to .* records' 'hash mismatch reports both digests'
    Assert-True (-not (Test-Path -LiteralPath $badHashRoot)) 'hash mismatch creates no tool root'
    Assert-True ((Get-TreeFileCount $badHashRoot) -eq 0) 'hash mismatch writes no file'

    # (b2) a manifest row with no archive entry.
    $ghostExe = New-FixtureExe -Name 'ghost' -Files @{ 'probe.txt' = $probeText } `
        -Rows @(
            [pscustomobject]@{ path = 'probe.txt'; sha256 = $probeHash },
            [pscustomobject]@{ path = 'ghost.txt'; sha256 = ('1' * 64) }
        )
    $ghostRoot = Join-Path $work 'roots\ghost'
    $r = Invoke-Installer -ExePath $ghostExe -Arguments @('--extract') -ToolRoot $ghostRoot
    Assert-True ($r.ExitCode -eq 2) "missing archive entry exits 2 (got $($r.ExitCode))"
    Assert-Match $r.StdErr 'ghost\.txt' 'missing archive entry names the row'
    Assert-Match $r.StdErr 'has no entry in the embedded payload' 'missing archive entry names the reason'
    Assert-True ((Get-TreeFileCount $ghostRoot) -eq 0) 'missing archive entry writes no file'

    # (b3) an archive entry with no manifest row (extra unverified bytes).
    $extraExe = New-FixtureExe -Name 'extra' -Files @{ 'probe.txt' = $probeText; 'extra.txt' = 'smuggled' } `
        -Rows @([pscustomobject]@{ path = 'probe.txt'; sha256 = $probeHash })
    $extraRoot = Join-Path $work 'roots\extra'
    $r = Invoke-Installer -ExePath $extraExe -Arguments @('--extract') -ToolRoot $extraRoot
    Assert-True ($r.ExitCode -eq 2) "unlisted archive entry exits 2 (got $($r.ExitCode))"
    Assert-Match $r.StdErr 'extra\.txt' 'unlisted archive entry names the file'
    Assert-Match $r.StdErr 'has no .* row' 'unlisted archive entry names the reason'
    Assert-True ((Get-TreeFileCount $extraRoot) -eq 0) 'unlisted archive entry writes no file'

    # The normal launch (no arguments) runs the same gate and stops before the UI.
    $r = Invoke-Installer -ExePath $badHashExe -Arguments @() -ToolRoot $badHashRoot
    Assert-True ($r.ExitCode -eq 2) "GUI launch with a tampered payload exits 2 (got $($r.ExitCode))"
    Assert-True ((Get-TreeFileCount $badHashRoot) -eq 0) 'GUI launch with a tampered payload writes no file'

    # --cli runs the same gate before the installed controller can start.
    $r = Invoke-Installer -ExePath $badHashExe -Arguments @('--cli', '-Action', 'status') -ToolRoot $badHashRoot
    Assert-True ($r.ExitCode -eq 2) "--cli with a tampered payload exits 2 (got $($r.ExitCode))"
    Assert-True ((Get-TreeFileCount $badHashRoot) -eq 0) '--cli with a tampered payload writes no file'
    Write-Output 'OK tampered: hash mismatch, missing entry and unlisted entry each exit 2 with no write (GUI and --cli)'

    # (b4) an entry that escapes the install root (ZipFile cannot make one, so
    # the zip is built entry by entry).
    $travDir = Join-Path $work 'traversal'
    New-Item -ItemType Directory -Force -Path $travDir | Out-Null
    $travZip = Join-Path $travDir 'payload.zip'
    $tfs = [IO.File]::Open($travZip, [IO.FileMode]::Create)
    try {
        $tza = New-Object IO.Compression.ZipArchive($tfs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $te = $tza.CreateEntry('../escape.txt')
            $ts = $te.Open()
            try {
                $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes('escape')
                $ts.Write($bytes, 0, $bytes.Length)
            }
            finally { $ts.Dispose() }
        }
        finally { $tza.Dispose() }
    }
    finally { $tfs.Dispose() }
    $travExe = New-ExeFromZip -Name 'traversal' -ZipPath $travZip
    $travRoot = Join-Path $work 'roots\traversal'
    $r = Invoke-Installer -ExePath $travExe -Arguments @('--extract') -ToolRoot $travRoot
    Assert-True ($r.ExitCode -eq 2) "escaping entry exits 2 (got $($r.ExitCode))"
    Assert-Match $r.StdErr 'escapes the install root' 'escaping entry names the containment guard'
    Assert-True ((Get-TreeFileCount $travRoot) -eq 0) 'escaping entry writes no file'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $work 'roots\escape.txt'))) 'escaping entry never lands outside the root'
    Write-Output 'OK traversal: ../escape.txt rejected by the containment guard'

    # ---- (c) zip-bomb cap ---------------------------------------------------
    $bombExe = New-BombExe -Name 'bomb'
    $bombRoot = Join-Path $work 'roots\bomb'
    $r = Invoke-Installer -ExePath $bombExe -Arguments @('--extract') -ToolRoot $bombRoot
    Assert-True ($r.ExitCode -eq 2) "zip bomb exits 2 (got $($r.ExitCode))"
    Assert-Match $r.StdErr '738197504-byte cap' 'zip bomb names the byte cap'
    Assert-Match $r.StdErr 'zip-bomb guard' 'zip bomb names the guard'
    Assert-True (-not (Test-Path -LiteralPath $bombRoot)) 'zip bomb creates no tool root'
    Assert-True ((Get-TreeFileCount $bombRoot) -eq 0) 'zip bomb writes no file'
    Write-Output 'OK bomb: 705 MiB declared payload rejected by the 704 MiB cap, nothing written'

    # ---- (c2) a reparse-point tool root is refused before extraction --------
    $junctionRoot = Join-Path $work 'roots\junction-root'
    $junctionTarget = Join-Path $work 'roots\junction-target'
    New-Item -ItemType Directory -Force -Path $junctionTarget | Out-Null
    cmd /c mklink /J "$junctionRoot" "$junctionTarget" > $null 2>&1
    if (Test-Path -LiteralPath $junctionRoot) {
        $r = Invoke-Installer -ExePath $exe -Arguments @('--extract') -ToolRoot $junctionRoot
        Assert-True ($r.ExitCode -eq 2) "junction tool root exits 2 (got $($r.ExitCode))"
        Assert-Match $r.StdErr 'reparse point' 'junction tool root names the reparse guard'
        Assert-True ((Get-TreeFileCount $junctionTarget) -eq 0) 'junction tool root receives no file'
        Write-Output 'OK reparse: a junction as the tool root is refused, target untouched'
    }
    else {
        Write-Output 'SKIP reparse: this host refused mklink /J (not a failure of the guard)'
    }

    # ---- (c3) a hardlinked install target is refused ------------------------
    $hardRoot = Join-Path $work 'roots\hardlink'
    $r = Invoke-Installer -ExePath $exe -Arguments @('--extract') -ToolRoot $hardRoot
    Assert-True ($r.ExitCode -eq 0) "hardlink case: seed extraction exit 0 (got $($r.ExitCode))"
    $outside = Join-Path $work 'outside.txt'
    [IO.File]::WriteAllText($outside, 'outside the tree', (New-Object Text.UTF8Encoding($false)))
    $hardVictim = Join-Path $hardRoot 'ARC-Icons.ps1'
    Remove-Item -LiteralPath $hardVictim -Force
    cmd /c mklink /H "$hardVictim" "$outside" > $null 2>&1
    if (Test-Path -LiteralPath $hardVictim) {
        $r = Invoke-Installer -ExePath $exe -Arguments @('--extract') -ToolRoot $hardRoot
        Assert-True ($r.ExitCode -eq 2) "hardlinked target exits 2 (got $($r.ExitCode))"
        Assert-Match $r.StdErr 'hardlinks' 'hardlinked target names the link guard'
        Assert-True (([IO.File]::ReadAllText($outside)) -eq 'outside the tree') 'hardlinked target outside the tree is not overwritten'
        Write-Output 'OK hardlink: a two-link install target is refused, the outside file is intact'
    }
    else {
        Write-Output 'SKIP hardlink: this host refused mklink /H (not a failure of the guard)'
    }

    # ---- (d) selftest still green ------------------------------------------
    $r = Invoke-Installer -ExePath $exe -Arguments @('--selftest') -ToolRoot (Join-Path $work 'roots\selftest')
    Assert-True ($r.ExitCode -eq 0) "selftest exit 0 (got $($r.ExitCode), stdout: $($r.StdOut))"
    Assert-Match $r.StdOut 'manifest: \d+/\d+ files verified' 'selftest reports manifest verification'
    Write-Output 'OK selftest: manifest verification green'
}
catch {
    $failed = $true
    Write-Output ('PAYLOAD-MANIFEST: FAIL - ' + $_.Exception.Message)
    Write-Output ('work dir kept for inspection: ' + $work)
}
finally {
    if (-not $failed) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failed) { exit 1 }
Write-Output ("PAYLOAD-MANIFEST: PASS ({0} checks; healthy extract + 3 tampered fixtures + zip-bomb cap + selftest)" -f $script:checks)

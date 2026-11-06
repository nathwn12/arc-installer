# ArcIcons-UserRefresh.ps1
# Per-user icon-cache refresh for EVERY logged-on interactive profile, from an
# elevated (or SYSTEM/session-0) context.
#
# Why this exists (measured 2026-11-06): the refresh used to read
# %LOCALAPPDATA% of the CALLER and stop every explorer.exe on the machine. Run
# elevated by an admin who is not the console user, or headless from the SYSTEM
# auto-repair task, it cleared the wrong profile's cache, killed other users'
# shells without restarting them, and the owning user still saw the old icons
# until they cleared iconcache + thumbcache by hand.
#
# What it does now:
#   - enumerates logged-on interactive sessions (WTSEnumerateSessions) and maps
#     each session's account to its SID + profile path via
#     HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList;
#   - refreshes the caller's own profile IN PROCESS (caller is already that user
#     and already in that session);
#   - refreshes every OTHER profile by registering a one-shot scheduled task
#     with an InteractiveToken principal for that user (no password, no TCB,
#     works for LOCAL and domain accounts), starting it, waiting for its
#     receipt, then deleting that task. The work therefore runs INSIDE the
#     target session under the target user's token, where %LOCALAPPDATA% and
#     "start explorer in my session" are correct by construction.
#   - the worker (bin\Refresh-UserIconCache.ps1) stops ONLY its own session's
#     explorer, deletes iconcache*.db AND thumbcache*.db (the old gap) plus the
#     legacy IconCache.db, runs ie4uinit -show, restarts explorer, and proves an
#     explorer pid is back in that same session before it writes ok=true.
#
# No side effects on dot-source. Windows PowerShell 5.1 compatible (the shipped
# payload runs under powershell.exe). Never touches SystemResources.
#
# Every call that mutates a shell is reachable only for a LIVE SystemResources
# directory (Invoke-ArcIconsPerUserIconCacheRefresh refuses a sandbox dir), so a
# sandbox proof never restarts a real shell.

if (-not (Get-Variable -Name ArcIconsUserRefreshHome -Scope Script -ErrorAction SilentlyContinue)) {
  $script:ArcIconsUserRefreshHome = $PSScriptRoot
}

# ---- WTS (logged-on sessions) -------------------------------------------------
function Initialize-ArcIconsWtsApi {
  if (([System.Management.Automation.PSTypeName]'ArcIcons.WtsApi').Type) { return }
  Add-Type -Namespace ArcIcons -Name WtsApi -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
private struct WTS_SESSION_INFO { public int SessionId; public IntPtr pWinStationName; public int State; }

[DllImport("wtsapi32.dll", SetLastError=true)]
private static extern bool WTSEnumerateSessions(IntPtr hServer, int Reserved, int Version, out IntPtr ppSessionInfo, out int pCount);

[DllImport("wtsapi32.dll", SetLastError=true)]
private static extern void WTSFreeMemory(IntPtr p);

[DllImport("wtsapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
private static extern bool WTSQuerySessionInformation(IntPtr hServer, int sessionId, int wtsInfoClass, out IntPtr ppBuffer, out int pBytesReturned);

// "id|state|station" per session. States: 0 Active, 1 Connected, 4 Disconnected.
public static string[] EnumerateSessions() {
  IntPtr pp; int count;
  if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out pp, out count) || pp == IntPtr.Zero) { return new string[0]; }
  System.Collections.Generic.List<string> list = new System.Collections.Generic.List<string>();
  try {
    int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
    for (int i = 0; i < count; i++) {
      IntPtr cur = new IntPtr(pp.ToInt64() + (long)i * size);
      WTS_SESSION_INFO si = (WTS_SESSION_INFO)Marshal.PtrToStructure(cur, typeof(WTS_SESSION_INFO));
      string station = Marshal.PtrToStringUni(si.pWinStationName);
      if (station == null) { station = ""; }
      list.Add(si.SessionId.ToString() + "|" + si.State.ToString() + "|" + station);
    }
  } finally { WTSFreeMemory(pp); }
  return list.ToArray();
}

// WTSUserName = 5, WTSDomainName = 7
public static string QueryString(int sessionId, int infoClass) {
  IntPtr buf; int len;
  if (!WTSQuerySessionInformation(IntPtr.Zero, sessionId, infoClass, out buf, out len) || buf == IntPtr.Zero) { return ""; }
  try { return Marshal.PtrToStringUni(buf); } finally { WTSFreeMemory(buf); }
}
'@
}

# Objects: SessionId, State (Active|Connected|Disconnected|Other), StateCode,
# Domain, User, Account (DOMAIN\user or "").
function Get-ArcIconsSessionTable {
  Initialize-ArcIconsWtsApi
  $rows = @()
  foreach ($line in @([ArcIcons.WtsApi]::EnumerateSessions())) {
    $parts = ([string]$line) -split '\|', 3
    if ($parts.Count -lt 3) { continue }
    $sid = 0
    $code = -1
    try { $sid = [int]$parts[0]; $code = [int]$parts[1] } catch { continue }
    if ($sid -eq 0) { continue }
    $user = ''
    $domain = ''
    try { $user = [string][ArcIcons.WtsApi]::QueryString($sid, 5) } catch { }
    try { $domain = [string][ArcIcons.WtsApi]::QueryString($sid, 7) } catch { }
    $account = ''
    if ($user) { $account = $user; if ($domain) { $account = $domain + '\' + $user } }
    $state = 'Other'
    if ($code -eq 0) { $state = 'Active' }
    elseif ($code -eq 1) { $state = 'Connected' }
    elseif ($code -eq 4) { $state = 'Disconnected' }
    $rows += [pscustomobject]@{
      SessionId = $sid; StateCode = $code; State = $state
      Domain = $domain; User = $user; Account = $account
    }
  }
  return @($rows | Sort-Object SessionId)
}

# ---- Profile table (SID -> profile path + account) ---------------------------
function Get-ArcIconsUserProfileTable {
  $base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
  $rows = @()
  foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
    $sid = [string]$k.PSChildName
    # user profiles only: local/domain (S-1-5-21-*) and Entra/AzureAD (S-1-12-1-*)
    if ($sid -notmatch '^S-1-(5-21|12-1)-') { continue }
    $path = ''
    try { $path = [string](Get-ItemProperty -LiteralPath $k.PSPath -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath } catch { continue }
    if (-not $path) { continue }
    if ($path -match '(?i)\\(System32|SysWOW64|Default|Default User|DefaultUser0)(\\|$)') { continue }
    $account = ''
    try { $account = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { }
    $rows += [pscustomobject]@{ Sid = $sid; Account = $account; ProfilePath = $path }
  }
  return @($rows)
}

function Get-ArcIconsProfilePathBySid([string]$Sid) {
  if (-not $Sid) { return '' }
  try {
    $p = (Get-ItemProperty -LiteralPath ("HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{0}" -f $Sid) -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
    return ([string]$p).TrimEnd('\')
  } catch { return '' }
}

function Get-ArcIconsProfileAccountBySid([string]$Sid) {
  try { return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { return '' }
}

# ---- Explorer per session ----------------------------------------------------
function Get-ArcIconsExplorerPids([int]$SessionId) {
  $pids = @()
  foreach ($p in @(Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
    if ($p.SessionId -eq $SessionId) { $pids += $p.Id }
  }
  return @($pids | Sort-Object)
}

function Stop-ArcIconsSessionExplorer([int]$SessionId) {
  $stopped = @()
  foreach ($id in @(Get-ArcIconsExplorerPids $SessionId)) {
    try { Stop-Process -Id $id -Force -ErrorAction Stop; $stopped += $id } catch { }
  }
  return @($stopped)
}

function Start-ArcIconsSessionExplorer([int]$SessionId, [int]$TimeoutSec = 20) {
  $exe = Join-Path $env:SystemRoot 'explorer.exe'
  $mySession = (Get-Process -Id $PID).SessionId
  if ($SessionId -ne $mySession) {
    return [pscustomobject]@{ Running = $false; Pids = @(); Note = ("cannot start explorer in session {0} from session {1}" -f $SessionId, $mySession) }
  }
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    if (@(Get-ArcIconsExplorerPids $SessionId).Count -gt 0) { break }
    try { Start-Process -FilePath $exe -ErrorAction Stop } catch { }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((@(Get-ArcIconsExplorerPids $SessionId).Count -eq 0) -and ((Get-Date) -lt $deadline)) {
      Start-Sleep -Milliseconds 250
    }
  }
  $pids = @(Get-ArcIconsExplorerPids $SessionId)
  if ($pids.Count -eq 0) {
    return [pscustomobject]@{ Running = $false; Pids = @(); Note = ("explorer.exe NOT running in session {0} after 2 x {1}s" -f $SessionId, $TimeoutSec) }
  }
  return [pscustomobject]@{ Running = $true; Pids = $pids; Note = ("explorer running in session {0} pid(s)={1}" -f $SessionId, ($pids -join ',')) }
}

# ---- Profile enumeration -----------------------------------------------------
# Every logged-on interactive profile, deduped by SID, plus the caller's own
# profile when it is interactive. Fields:
#   Sid, Account, ProfilePath, SessionId, SessionState, ExplorerPids, Resolved
# Resolved=$false marks a logged-on session whose profile row could not be
# matched (that profile can NOT be refreshed; callers must report it, not skip).
function Get-ArcIconsLoggedOnProfiles {
  $table = @(Get-ArcIconsUserProfileTable)
  $sessions = @(Get-ArcIconsSessionTable)
  $out = @()
  $seen = @{}
  foreach ($s in $sessions) {
    if (-not $s.Account) { continue }
    if ($s.StateCode -eq 6 -or $s.StateCode -eq 8) { continue }   # Listen / Down
    $match = $null
    foreach ($row in $table) {
      if ($row.Account -and ($row.Account -ieq $s.Account)) { $match = $row; break }
    }
    if (-not $match) {
      $bare = $s.User
      foreach ($row in $table) {
        if (-not $bare) { break }
        $accBare = ''
        if ($row.Account) { $accBare = (($row.Account -split '\\')[-1]) }
        $leaf = ''
        try { $leaf = Split-Path -Leaf $row.ProfilePath } catch { }
        if ($accBare -ieq $bare -or $leaf -ieq $bare) { $match = $row; break }
      }
    }
    $entry = [pscustomobject]@{
      Sid = ''; Account = $s.Account; ProfilePath = ''; SessionId = [int]$s.SessionId
      SessionState = [string]$s.State; ExplorerPids = @(Get-ArcIconsExplorerPids ([int]$s.SessionId)); Resolved = $false
    }
    if ($match) {
      if ($seen[$match.Sid]) { continue }
      $seen[$match.Sid] = $true
      $entry.Sid = $match.Sid
      $entry.Account = $match.Account
      $entry.ProfilePath = $match.ProfilePath
      $entry.Resolved = $true
    }
    $out += $entry
  }
  # Caller's own profile: WTS can be unavailable in odd remoting contexts, but
  # the caller is by definition a live interactive user when session != 0.
  try {
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $mySid = $me.User.Value
    $mySession = (Get-Process -Id $PID).SessionId
    if (($mySession -ne 0) -and (-not $seen[$mySid]) -and ($mySid -notmatch '^S-1-5-(18|19|20)$')) {
      $myPath = Get-ArcIconsProfilePathBySid $mySid
      if ($myPath) {
        $seen[$mySid] = $true
        $out += [pscustomobject]@{
          Sid = $mySid; Account = $me.Name; ProfilePath = $myPath; SessionId = $mySession
          SessionState = 'Active'; ExplorerPids = @(Get-ArcIconsExplorerPids $mySession); Resolved = $true
        }
      }
    }
  } catch { }
  return @($out | Sort-Object SessionId)
}

# ---- Cache drop (runs INSIDE the target profile/session) ---------------------
# Stop that session's explorer first: iconcache/thumbcache files are held open
# by the running shell, so a delete-first order silently fails (the old bug).
function Invoke-ArcIconsProfileCacheDrop {
  param(
    [Parameter(Mandatory = $true)][string]$ProfilePath,
    [int]$SessionId = -1
  )
  $deleted = @()
  $stopped = @()
  $sidNow = $SessionId
  if ($sidNow -lt 0) { $sidNow = (Get-Process -Id $PID).SessionId }
  $stopped = @(Stop-ArcIconsSessionExplorer $sidNow)
  if ($stopped.Count -gt 0) { Start-Sleep -Milliseconds 1500 }
  $explorerDir = Join-Path $ProfilePath 'AppData\Local\Microsoft\Windows\Explorer'
  $localDir = Join-Path $ProfilePath 'AppData\Local'
  $patterns = @(
    [pscustomobject]@{ Dir = $explorerDir; Filter = 'iconcache*.db' }
    [pscustomobject]@{ Dir = $explorerDir; Filter = 'thumbcache*.db' }
    [pscustomobject]@{ Dir = $localDir;    Filter = 'IconCache.db' }
  )
  foreach ($pat in $patterns) {
    if (-not (Test-Path -LiteralPath $pat.Dir -PathType Container)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $pat.Dir -Filter $pat.Filter -File -Force -ErrorAction SilentlyContinue)) {
      try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $deleted += $f.Name } catch { }
    }
  }
  try { & "$env:SystemRoot\System32\ie4uinit.exe" -show 2>$null | Out-Null } catch { }
  $shell = Start-ArcIconsSessionExplorer $SessionId
  return [pscustomobject]@{ Deleted = @($deleted); Stopped = @($stopped); Shell = $shell }
}

# ---- One-shot interactive-token task (parent side) ---------------------------
# Registers an InteractiveToken task for the target user (no password needed),
# starts it, waits for the worker's receipt, then removes exactly that task.
# The name is generated per run, so no existing task is ever overwritten.
function Invoke-ArcIconsScheduledProfileRefresh {
  param(
    $Profile,
    [string]$Worker,
    [string]$ReceiptDir,
    [switch]$DryRun,
    [int]$TimeoutSec = 45
  )
  $result = [pscustomobject]@{ Ok = $false; Mode = 'scheduled-task'; Note = ''; Receipt = $null }
  if (-not $Worker -or (-not (Test-Path -LiteralPath $Worker -PathType Leaf))) {
    $result.Note = ("worker missing: {0}" -f $Worker); return $result
  }
  if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    $result.Note = 'ScheduledTasks module unavailable'; return $result
  }
  if (-not $Profile.Resolved -or -not $Profile.Sid) {
    $result.Note = ("no profile row for {0} (session {1}): cannot refresh" -f $Profile.Account, $Profile.SessionId); return $result
  }
  if (-not (Test-Path -LiteralPath $ReceiptDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null
  }
  $stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $taskName = 'ArcIcons-Refresh-' + $stamp
  $receipt = Join-Path $ReceiptDir ("refresh-{0}-{1}.json" -f ($Profile.Sid -replace '[^0-9]', ''), $stamp)
  $pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProfileSid {1} -ReceiptPath "{2}"' -f $Worker, $Profile.Sid, $receipt
  if ($DryRun) { $argLine += ' -DryRun' }
  $userId = $Profile.Account
  if (-not $userId) { $userId = $Profile.Sid }
  $action = New-ScheduledTaskAction -Execute $pwsh -Argument $argLine
  $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
  $registered = $false
  $taskCode = $null
  try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Description 'ArcIcons: one-shot per-user icon cache refresh (removed automatically).' -ErrorAction Stop | Out-Null
    $registered = $true
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
      if (Test-Path -LiteralPath $receipt -PathType Leaf) {
        try { $result.Receipt = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json } catch { $result.Receipt = $null }
        if ($result.Receipt) { break }
      }
      Start-Sleep -Milliseconds 350
    }
    try {
      $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
      $taskCode = $info.LastTaskResult
    } catch { }
  } catch {
    $result.Note = ("scheduled-task registration/run failed: {0}" -f $_)
    return $result
  } finally {
    if ($registered) {
      try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch { }
      try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    }
  }
  if (-not $result.Receipt) {
    $extra = ''
    if ($null -ne $taskCode) { $extra = (" taskLastResult=0x{0:X}" -f $taskCode) }
    $result.Note = ("no receipt within {0}s for {1} (session {2});{3}" -f $TimeoutSec, $Profile.Account, $Profile.SessionId, $extra)
    return $result
  }
  $rec = $result.Receipt
  if (-not $rec.ok) {
    $result.Note = ("worker refused: {0} (session {1})" -f ([string]$rec.reason), $Profile.SessionId)
    return $result
  }
  if ($DryRun) {
    if (([string]$rec.sid -ne [string]$Profile.Sid) -or ([int]$rec.sessionId -ne [int]$Profile.SessionId)) {
      $result.Note = ("receipt mismatch: sid={0} session={1}, expected sid={2} session={3}" -f $rec.sid, $rec.sessionId, $Profile.Sid, $Profile.SessionId)
      return $result
    }
    $result.Ok = $true
    $result.Note = ("dry-run ran in session {0} as {1}; profile {2}" -f $rec.sessionId, $rec.account, $rec.profilePath)
    return $result
  }
  $pids = @(Get-ArcIconsExplorerPids ([int]$Profile.SessionId))
  if ($pids.Count -eq 0) {
    $result.Note = ("worker receipt ok but no explorer in session {0}" -f $Profile.SessionId)
    return $result
  }
  $result.Ok = $true
  $result.Note = ("scheduled-task; session {0}; explorer pid(s)={1}; cache files={2}" -f $Profile.SessionId, ($pids -join ','), @($rec.deleted).Count)
  return $result
}

# ---- Parent entry ------------------------------------------------------------
# Refreshes EVERY logged-on interactive profile. Returns a structured object
# (Ok, Skipped, Note, Profiles, Failures); Invoke-ArcIconsIconCacheRefresh
# wraps it as the one-line note the apply/restore journals have always stored.
function Invoke-ArcIconsPerUserIconCacheRefresh {
  param(
    [string]$Root = (Join-Path $env:ProgramData 'ArcIcons'),
    [string]$SysDir = (Join-Path $env:SystemRoot 'SystemResources'),
    [bool]$Skip = $false,
    [switch]$DryRun
  )
  $result = [pscustomobject]@{
    Ok = $false; Skipped = $false; DryRun = [bool]$DryRun; Note = ''
    Profiles = @(); Failures = @()
  }
  if ($Skip) { $result.Skipped = $true; $result.Ok = $true; $result.Note = 'skipped (-SkipIconCacheRefresh)'; return $result }
  $liveDefault = ''
  try { $liveDefault = Resolve-ArcIconsCanonicalPath (Join-Path $env:SystemRoot 'SystemResources') } catch { }
  if (-not $liveDefault -or ((Resolve-ArcIconsCanonicalPath $SysDir) -ine $liveDefault)) {
    $result.Skipped = $true; $result.Ok = $true
    $result.Note = 'skipped (non-live SystemResourceDir; shell untouched)'
    return $result
  }
  $profiles = @(Get-ArcIconsLoggedOnProfiles)
  if ($profiles.Count -eq 0) {
    $result.Note = 'multi-user refresh: no logged-on interactive profile found (nothing to refresh)'
    return $result
  }
  $mySid = ''
  $mySession = (Get-Process -Id $PID).SessionId
  try { $mySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
  $rootC = $Root
  if (-not $rootC) { $rootC = Join-Path $env:ProgramData 'ArcIcons' }
  $receiptDir = Join-Path $rootC 'logs\refresh'
  $worker = Join-Path $script:ArcIconsUserRefreshHome 'Refresh-UserIconCache.ps1'
  $parts = @()
  $failures = @()
  $rows = @()
  foreach ($p in $profiles) {
    if (-not $p.Resolved) {
      $failures += ("{0} (session {1}): no profile row" -f $p.Account, $p.SessionId)
      $rows += [pscustomobject]@{ Account = $p.Account; SessionId = $p.SessionId; Mode = 'unresolved'; Ok = $false; Note = 'no ProfileList row' }
      continue
    }
    if ($DryRun) {
      $mode = 'in-process'
      if (-not (($p.SessionId -eq $mySession) -and ($p.Sid -eq $mySid))) { $mode = 'scheduled-task' }
      $rows += [pscustomobject]@{ Account = $p.Account; SessionId = $p.SessionId; Mode = $mode; Ok = $true; Note = 'would drop iconcache+thumbcache and restart explorer' }
      $parts += ("session {0} {1} [{2} dry-run]" -f $p.SessionId, $p.Account, $mode)
      continue
    }
    if (($p.SessionId -eq $mySession) -and ($p.Sid -eq $mySid) -and ($mySession -ne 0)) {
      try {
        $r = Invoke-ArcIconsProfileCacheDrop -ProfilePath $p.ProfilePath -SessionId $p.SessionId
        $ok = ($null -ne $r.Shell) -and $r.Shell.Running
        $rows += [pscustomobject]@{ Account = $p.Account; SessionId = $p.SessionId; Mode = 'in-process'; Ok = $ok; Note = $r.Shell.Note }
        if ($ok) { $parts += ("session {0} {1} [in-process; {2} cache files]" -f $p.SessionId, $p.Account, $r.Deleted.Count) }
        else { $failures += ("{0} (session {1}): {2}" -f $p.Account, $p.SessionId, $r.Shell.Note) }
      } catch {
        $rows += [pscustomobject]@{ Account = $p.Account; SessionId = $p.SessionId; Mode = 'in-process'; Ok = $false; Note = "$_" }
        $failures += ("{0} (session {1}): {2}" -f $p.Account, $p.SessionId, $_)
      }
      continue
    }
    $t = Invoke-ArcIconsScheduledProfileRefresh -Profile $p -Worker $worker -ReceiptDir $receiptDir -DryRun:$DryRun
    $rows += [pscustomobject]@{ Account = $p.Account; SessionId = $p.SessionId; Mode = 'scheduled-task'; Ok = [bool]$t.Ok; Note = $t.Note }
    if ($t.Ok) { $parts += ("session {0} {1} [{2}]" -f $p.SessionId, $p.Account, $t.Note) }
    else { $failures += ("{0} (session {1}): {2}" -f $p.Account, $p.SessionId, $t.Note) }
  }
  $result.Profiles = @($rows)
  $result.Failures = @($failures)
  $result.Ok = ($failures.Count -eq 0) -and (@($rows | Where-Object { -not $_.Ok }).Count -eq 0)
  $head = 'multi-user refresh: {0} profile(s)' -f $profiles.Count
  if ($DryRun) { $head = 'multi-user refresh (dry-run): {0} profile(s)' -f $profiles.Count }
  $txt = $head + '; ' + (($parts) -join '; ')
  if ($failures.Count -gt 0) {
    $txt = $head + '; FAILED: ' + ($failures -join '; ')
    if ($parts.Count -gt 0) { $txt += '; refreshed: ' + ($parts -join '; ') }
  }
  $result.Note = $txt
  return $result
}

<#
.SYNOPSIS
  Self-healing Windows portproxy + allowlist-scoped firewall rule for the credo LAN
  peer relay on WSL2 in default NAT mode.

.DESCRIPTION
  In WSL2 default NAT mode the WSL daemon is NOT reachable from other machines on the
  LAN: it sits behind a NAT that only the Windows host can see, and its IP changes on
  every WSL restart. To let a LAN peer reach the relay daemon (which listens on
  0.0.0.0:PORT inside WSL), the Windows host must forward its own LAN-IP:PORT to the
  current WSL IP:PORT (a netsh portproxy) and allow that port inbound in the firewall.

  Under NAT the WSL daemon only ever sees the WSL gateway as the source address, so it
  cannot filter peers itself. The REAL per-source boundary is therefore the Windows
  firewall rule, whose RemoteAddress is set to exactly the relay's effective allowlist:
    - the WSL daemon writes the allowlist as a DATA file to
      %LOCALAPPDATA%\credo\peer-lan-allow.json (only when it changes) and triggers the
      scheduled task,
    - the elevated task runs -Refresh, which STRICTLY re-validates every entry itself
      (private ranges only, no wildcard, no CIDR broader than /8; invalid entries are
      dropped and logged) and then either DISABLES the rule (disabled, missing file or
      no valid entry - never an empty RemoteAddress, which would mean Any) or sets
      RemoteAddress to exactly the validated list (replace, never append) and Profile
      to the validated windows_profiles (default Private), enables the rule and
      refreshes the portproxy.

  SECURITY: the elevated task never runs a script from a user-writable location.
  -Install copies this script to %ProgramData%\credo\, locks that folder down so only
  Administrators and SYSTEM can write (users may read/execute), and registers the task
  to run THAT copy. The data file is the only user-writable input and it is treated as
  untrusted data.

  On NATIVE Linux there is no NAT and the daemon already listens on the LAN directly,
  so this script is not needed there (see the plugin README / peer-lan command docs).

.PARAMETER Port
  The TCP port to forward. MUST match listen_port in ~/.claude/credo/peer-lan.json
  (default 48610).

.PARAMETER Install
  One-time setup (REQUIRES an elevated / Administrator PowerShell): copy this script to
  %ProgramData%\credo (admin-only write ACL), create the firewall rule (disabled until
  the first refresh), register the scheduled task (TaskName) that runs the installed
  copy with -Refresh, elevated, at startup and on demand, and run one -Refresh now.
  Idempotent: re-running updates the copy, rule and task in place. Re-run it once after
  a plugin update that bumps $ScriptVersion (the relay's `check` tells you).

.PARAMETER Uninstall
  Remove the scheduled task, the firewall rule, the portproxy entry for Port and the
  installed copy (REQUIRES an elevated / Administrator PowerShell).

.PARAMETER Refresh
  Apply the allowlist data file to the firewall rule and re-point the portproxy at the
  current WSL IP. This is the action the scheduled task runs (elevated).

.PARAMETER DryRun
  Change nothing; print what -Install / -Refresh / -Uninstall would do (for tests and
  for inspecting a data file). Needs no elevation.

.PARAMETER AllowFile
  Path of the allowlist data file (default %LOCALAPPDATA%\credo\peer-lan-allow.json of
  the user running -Install for the default port 48610, peer-lan-allow-<Port>.json for
  any other port; recorded in the task so it works for the S4U task too). The firewall
  rule ("credo-peer-lan <Port>") and the applied-state file are per port as well, so a
  second instance with its own -Port and -TaskName never touches the first one.

.PARAMETER TaskName
  Name of the scheduled task (default "credo-peer-lan-proxy").

.EXAMPLE
  # One time per machine, in an ELEVATED Windows PowerShell:
  powershell -NoProfile -ExecutionPolicy Bypass -File credo-peer-lan-winproxy.ps1 -Install -Port 48610

.NOTES
  This script is invoked by the user in Windows PowerShell (and by the Task Scheduler),
  never by the WSL bash hook directly. The WSL side only writes the data file and
  triggers the already-registered task on demand.
#>

[CmdletBinding()]
param(
    [int]$Port = 48610,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Refresh,
    [switch]$DryRun,
    [string]$AllowFile = "",
    [string]$TaskName = "credo-peer-lan-proxy"
)

$ErrorActionPreference = "Stop"

# Version of THIS script. Bump it by hand whenever the script changes: the WSL relay
# compares it with the copy installed in %ProgramData%\credo and tells the user to
# re-run -Install once (one UAC prompt) when the installed copy is older.
$ScriptVersion = 3

$ScriptPath = $MyInvocation.MyCommand.Path
$InstallDir = Join-Path $env:ProgramData "credo"
$InstalledScript = Join-Path $InstallDir "credo-peer-lan-winproxy.ps1"
# Per-port names so a second relay instance (other -Port, own -TaskName) never
# overwrites the first one's rule, data file or applied state. The default port keeps
# the original names (backward compatible with an existing install). The WSL side
# (win_port_suffix in credo-peer-lan.py) uses the same scheme.
$PortSuffix = if ($Port -eq 48610) { "" } else { "-$Port" }
$AppliedFile = Join-Path $InstallDir ("peer-lan-applied{0}.json" -f $PortSuffix)
$RuleName = "credo-peer-lan $Port"
if ([string]::IsNullOrWhiteSpace($AllowFile)) {
    $AllowFile = Join-Path $env:LOCALAPPDATA ("credo\peer-lan-allow{0}.json" -f $PortSuffix)
}

function Test-Admin {
    # True when the current PowerShell runs elevated (member of the Administrators role).
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Plan([string]$Text) {
    Write-Host ("DRYRUN: would {0}" -f $Text)
}

# -- allowlist validation (mirrors parse_allow_entry in credo-peer-lan.py) ---------
function ConvertTo-IpNumber([string]$Text) {
    # strict dotted IPv4 -> int64, or $null
    $t = $Text.Trim()
    if ($t -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $null }
    [int64]$v = 0
    for ($i = 1; $i -le 4; $i++) {
        $o = [int64]$Matches[$i]
        if ($o -gt 255) { return $null }
        $v = $v * 256 + $o
    }
    return $v
}

function ConvertFrom-IpNumber([int64]$V) {
    return ("{0}.{1}.{2}.{3}" -f (($V -shr 24) -band 255), (($V -shr 16) -band 255), (($V -shr 8) -band 255), ($V -band 255))
}

function Test-PrivateSpan([int64]$Lo, [int64]$Hi) {
    # both ends inside ONE of 10/8, 172.16/12, 192.168/16, 127/8
    $blocks = @(
        @((ConvertTo-IpNumber "10.0.0.0"), (ConvertTo-IpNumber "10.255.255.255")),
        @((ConvertTo-IpNumber "172.16.0.0"), (ConvertTo-IpNumber "172.31.255.255")),
        @((ConvertTo-IpNumber "192.168.0.0"), (ConvertTo-IpNumber "192.168.255.255")),
        @((ConvertTo-IpNumber "127.0.0.0"), (ConvertTo-IpNumber "127.255.255.255"))
    )
    foreach ($b in $blocks) {
        if ($Lo -ge $b[0] -and $Hi -le $b[1]) { return $true }
    }
    return $false
}

function Test-CredoAllowEntry($Entry) {
    # Returns @{ Ok = $true; Text = <canonical> } or @{ Ok = $false; Reason = <why> }.
    # The data file holds only expanded addresses: the keywords "peers"/"home" are
    # expanded on the WSL side, so they are invalid here.
    if (-not ($Entry -is [string])) { return @{ Ok = $false; Reason = "not a string" } }
    $t = $Entry.Trim()
    if ($t -eq "") { return @{ Ok = $false; Reason = "empty" } }
    if ($t.Contains("*") -or @("any", "all", "everything", "0.0.0.0", "0.0.0.0/0", "::/0", "localsubnet", "internet") -contains $t.ToLower()) {
        return @{ Ok = $false; Reason = "wildcard" }
    }
    if ($t.Contains("/")) {
        $parts = $t.Split("/")
        if ($parts.Count -ne 2 -or $parts[1] -notmatch '^\d{1,2}$') { return @{ Ok = $false; Reason = "malformed CIDR" } }
        $ip = ConvertTo-IpNumber $parts[0]
        $pfx = [int]$parts[1]
        if ($null -eq $ip -or $pfx -gt 32) { return @{ Ok = $false; Reason = "malformed CIDR" } }
        if ($pfx -lt 8) { return @{ Ok = $false; Reason = "broader than /8" } }
        [int64]$size = [int64][math]::Pow(2, 32 - $pfx)
        [int64]$lo = $ip - ($ip % $size)
        [int64]$hi = $lo + $size - 1
        if ($pfx -eq 32) { $canon = ConvertFrom-IpNumber $lo } else { $canon = "{0}/{1}" -f (ConvertFrom-IpNumber $lo), $pfx }
    }
    elseif ($t.Contains("-")) {
        $parts = $t.Split("-")
        if ($parts.Count -ne 2) { return @{ Ok = $false; Reason = "malformed range" } }
        $lo = ConvertTo-IpNumber $parts[0]
        $hi = ConvertTo-IpNumber $parts[1]
        if ($null -eq $lo -or $null -eq $hi -or $lo -gt $hi) { return @{ Ok = $false; Reason = "malformed range" } }
        if ($lo -eq $hi) { $canon = ConvertFrom-IpNumber $lo } else { $canon = "{0}-{1}" -f (ConvertFrom-IpNumber $lo), (ConvertFrom-IpNumber $hi) }
    }
    else {
        $lo = ConvertTo-IpNumber $t
        if ($null -eq $lo) { return @{ Ok = $false; Reason = "not an IPv4 address" } }
        $hi = $lo
        $canon = ConvertFrom-IpNumber $lo
    }
    if (-not (Test-PrivateSpan $lo $hi)) { return @{ Ok = $false; Reason = "not private (public ranges are not supported)" } }
    return @{ Ok = $true; Text = $canon }
}

function Get-RefreshPlan([string]$Path) {
    # Read + strictly validate the data file. Anything unexpected -> disabled.
    $plan = @{ Enabled = $false; Remote = @(); Profiles = @("Private"); Dropped = @(); Reason = "" }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $plan.Reason = "data file missing: $Path"
        return $plan
    }
    try {
        $data = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $plan.Reason = "data file unreadable: $Path"
        return $plan
    }
    $profiles = @()
    foreach ($p in @($data.windows_profiles)) {
        foreach ($ok in @("Private", "Domain", "Public")) {
            if ($p -is [string] -and $p.Trim() -ieq $ok -and $profiles -notcontains $ok) { $profiles += $ok }
        }
    }
    if ($profiles.Count -eq 0) { $profiles = @("Private") }
    $plan.Profiles = $profiles
    $remote = @()
    foreach ($e in @($data.allow)) {
        if ($null -eq $e) { continue }
        $r = Test-CredoAllowEntry $e
        if ($r.Ok) {
            if ($remote -notcontains $r.Text) { $remote += $r.Text }
        }
        else {
            $plan.Dropped += ("{0} ({1})" -f $e, $r.Reason)
        }
    }
    $plan.Remote = $remote
    if ($data.enabled -ne $true) {
        $plan.Reason = "relay reports LAN disabled"
        return $plan
    }
    if ($remote.Count -eq 0) {
        $plan.Reason = "no valid allowlist entry"
        return $plan
    }
    $plan.Enabled = $true
    $plan.Reason = "allowlist applied"
    return $plan
}

function Get-WslIp {
    # Current default-distro WSL IPv4, as seen from the Windows host. The daemon binds
    # 0.0.0.0 inside WSL, so any WSL IP reaches it; we take the first IPv4 token of
    # `wsl hostname -I`. wsl.exe output can carry trailing CR / NUL bytes and several
    # space-separated addresses, so normalize and pick the first valid IPv4.
    # wsl.exe may print warnings to stderr (e.g. "Processing /etc/fstab with mount -a
    # failed" from a failing mount). Under $ErrorActionPreference='Stop' that stderr
    # surfaces as a terminating NativeCommandError and would abort the refresh before
    # netsh runs, so neutralize the preference locally and read stdout only.
    $raw = $null
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = (& wsl.exe hostname -I 2>$null) }
    catch { $raw = $null }
    finally { $ErrorActionPreference = $prev }
    if ($null -eq $raw) { return $null }
    $text = ($raw -join " ") -replace "`0", ""
    foreach ($tok in ($text -split "\s+")) {
        $t = $tok.Trim()
        if ($t -match "^\d{1,3}(\.\d{1,3}){3}$") { return $t }
    }
    return $null
}

function Set-PortProxy([int]$Port) {
    $wslip = Get-WslIp
    if ([string]::IsNullOrWhiteSpace($wslip)) {
        throw "Could not determine the WSL IP (wsl.exe hostname -I returned nothing). Is WSL installed and a default distro set?"
    }
    # Idempotent reset: delete any existing mapping for this listen port (ignore if
    # absent), then add the current one.
    & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$Port 2>$null | Out-Null
    & netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$Port connectaddress=$wslip connectport=$Port
    if ($LASTEXITCODE -ne 0) {
        throw "netsh portproxy add failed (exit $LASTEXITCODE). Are you elevated?"
    }
    Write-Host ("Portproxy set: 0.0.0.0:{0} -> {1}:{0}" -f $Port, $wslip)
}

function Write-AppliedState($Plan) {
    $state = [ordered]@{
        script_version = $ScriptVersion
        enabled        = [bool]$Plan.Enabled
        remote_address = @($Plan.Remote)
        profiles       = @($Plan.Profiles)
        dropped        = @($Plan.Dropped)
        reason         = $Plan.Reason
        applied_at     = (Get-Date).ToString("s")
    }
    if (Test-Path -LiteralPath $InstallDir -PathType Container) {
        ($state | ConvertTo-Json -Compress) | Set-Content -LiteralPath $AppliedFile -Encoding UTF8
    }
}

function Invoke-ApplyPlan($Plan, [int]$Port) {
    foreach ($d in $Plan.Dropped) { Write-Warning ("allowlist entry dropped: {0}" -f $d) }
    if ($DryRun) {
        if ($Plan.Enabled) {
            Write-Plan ("set firewall rule '{0}': RemoteAddress={1} Profile={2} Enabled=True" -f $RuleName, ($Plan.Remote -join ","), ($Plan.Profiles -join ","))
            Write-Plan ("refresh the portproxy 0.0.0.0:{0} -> <current WSL IP>:{0}" -f $Port)
        }
        else {
            Write-Plan ("DISABLE firewall rule '{0}' ({1})" -f $RuleName, $Plan.Reason)
            Write-Plan ("remove the portproxy for listenport {0}" -f $Port)
        }
        return
    }
    if (-not (Test-Admin)) {
        throw "Refresh changes the firewall and netsh portproxy, which needs Administrator rights. Let the scheduled task run it, or use an elevated PowerShell."
    }
    $rule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if (-not $rule) {
        # created DISABLED; enabled below only with a validated, non-empty RemoteAddress
        New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Private -Enabled False | Out-Null
    }
    if (-not $Plan.Enabled) {
        # NEVER set an empty RemoteAddress (empty = Any): disable the rule instead
        Set-NetFirewallRule -DisplayName $RuleName -Enabled False
        & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$Port 2>$null | Out-Null
        Write-Host ("Firewall rule '{0}' DISABLED ({1}); portproxy removed." -f $RuleName, $Plan.Reason)
        Write-AppliedState $Plan
        return
    }
    # replace (never append) -> entries removed from the allowlist are cleaned up
    Set-NetFirewallRule -DisplayName $RuleName -RemoteAddress $Plan.Remote -Profile $Plan.Profiles -Enabled True
    Write-Host ("Firewall rule '{0}' ENABLED: RemoteAddress={1} Profile={2}" -f $RuleName, ($Plan.Remote -join ","), ($Plan.Profiles -join ","))
    Set-PortProxy -Port $Port
    Write-AppliedState $Plan
}

function Get-FileStamp([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return ""
}

function Invoke-Refresh {
    param([int]$Port)
    # Loop a few times: the WSL side may rewrite the data file while a refresh runs
    # (the task ignores a trigger while it is still running), so re-apply until the
    # file is unchanged across one pass.
    for ($i = 0; $i -lt 3; $i++) {
        $before = Get-FileStamp $AllowFile
        $plan = Get-RefreshPlan $AllowFile
        Invoke-ApplyPlan $plan $Port
        if ($DryRun -or (Get-FileStamp $AllowFile) -eq $before) { break }
    }
}

function Set-AdminOnlyAcl([string]$Path, [bool]$IsDir) {
    # Owner Administrators, inheritance cut, ONLY: Administrators + SYSTEM full,
    # Users read/execute. A fresh security object replaces every existing ACE, so
    # nothing a user may have planted survives.
    $admins = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $system = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
    $users = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-545")
    if ($IsDir) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    }
    else {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]::None
    }
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $acl.SetOwner($admins)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, "FullControl", $inherit, $prop, $allow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, "FullControl", $inherit, $prop, $allow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($users, "ReadAndExecute", $inherit, $prop, $allow)))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Invoke-Install {
    param([int]$Port, [string]$TaskName)

    if (-not $DryRun -and -not (Test-Admin)) {
        throw "-Install needs an elevated PowerShell. Right-click Windows PowerShell and choose 'Run as administrator', then re-run with -Install."
    }

    # (a) secure install location. Refuse a planted junction/symlink.
    if (Test-Path -LiteralPath $InstallDir) {
        $item = Get-Item -LiteralPath $InstallDir -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "$InstallDir is a junction/symlink - refusing to install there. Remove it manually and re-run -Install."
        }
    }
    if ($DryRun) {
        Write-Plan ("create {0} with an admin-only write ACL (Administrators/SYSTEM full, Users read+execute)" -f $InstallDir)
        Write-Plan ("copy {0} -> {1} (script v{2})" -f $ScriptPath, $InstalledScript, $ScriptVersion)
        Write-Plan ("(re)create firewall rule '{0}' DISABLED until the first refresh" -f $RuleName)
        Write-Plan ("register task '{0}' running {1} -Refresh -Port {2} -AllowFile {3}" -f $TaskName, $InstalledScript, $Port, $AllowFile)
        Invoke-Refresh -Port $Port
        return
    }
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir | Out-Null
    }
    Set-AdminOnlyAcl $InstallDir $true
    if ($ScriptPath -ne $InstalledScript) {
        if (Test-Path -LiteralPath $InstalledScript) { Remove-Item -LiteralPath $InstalledScript -Force }
        Copy-Item -LiteralPath $ScriptPath -Destination $InstalledScript
    }
    Set-AdminOnlyAcl $InstalledScript $false
    Write-Host ("Installed script v{0}: {1} (admin-only write)" -f $ScriptVersion, $InstalledScript)

    # (b) firewall rule, recreated DISABLED; -Refresh scopes and enables it from the
    # validated allowlist (never LocalSubnet/Any any more).
    Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Private -Enabled False | Out-Null
    Write-Host ("Firewall rule ensured: '{0}' (TCP {1}, inbound, disabled until refresh)" -f $RuleName, $Port)

    # (c) Scheduled task that runs the INSTALLED copy with -Refresh. It runs elevated
    # (RunLevel Highest) at every startup, S4U (no stored password). A non-elevated
    # caller (the WSL side) can trigger it with `schtasks /Run /TN <name>` and gets NO
    # UAC prompt - the elevation lives in the task definition, not in the caller.
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`" -Refresh -Port {1} -AllowFile `"{2}`"" -f $InstalledScript, $Port, $AllowFile)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
        -LogonType S4U -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host ("Scheduled task registered: '{0}' -> {1} (elevated, at startup + on demand)" -f $TaskName, $InstalledScript)

    # (d) apply now
    Invoke-Refresh -Port $Port

    Write-Host ""
    Write-Host "Install complete. The firewall allowlist and portproxy now refresh automatically"
    Write-Host "at Windows startup and whenever the WSL relay updates its allowlist."
}

function Invoke-Uninstall {
    param([int]$Port, [string]$TaskName)

    if ($DryRun) {
        Write-Plan ("remove task '{0}', firewall rule '{1}', the portproxy for {2}, the applied state {3} and the installed copy in {4} unless another task still uses it" -f $TaskName, $RuleName, $Port, $AppliedFile, $InstallDir)
        return
    }
    if (-not (Test-Admin)) {
        throw "-Uninstall needs an elevated PowerShell. Run as administrator, then re-run with -Uninstall."
    }
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host ("Scheduled task removed: '{0}'" -f $TaskName)
    }
    else {
        Write-Host ("Scheduled task '{0}' not present; nothing to remove." -f $TaskName)
    }
    $rule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if ($rule) {
        $rule | Remove-NetFirewallRule
        Write-Host ("Firewall rule removed: '{0}'" -f $RuleName)
    }
    else {
        Write-Host ("Firewall rule '{0}' not present; nothing to remove." -f $RuleName)
    }
    & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$Port 2>$null | Out-Null
    Write-Host ("Portproxy entry for listenport {0} removed (if any)." -f $Port)
    if (Test-Path -LiteralPath $AppliedFile -PathType Leaf) { Remove-Item -LiteralPath $AppliedFile -Force }
    # The installed script copy is shared by every instance (one copy, many tasks):
    # keep it while any other scheduled task still runs it.
    $others = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -ne $TaskName -and (($_.Actions | ForEach-Object { $_.Arguments }) -join " ") -like ("*{0}*" -f $InstalledScript)
    })
    if ($others.Count -gt 0) {
        Write-Host ("Installed copy kept in {0}: still used by task(s) {1}." -f $InstallDir, (($others | ForEach-Object { $_.TaskName }) -join ", "))
    }
    else {
        if (Test-Path -LiteralPath $InstalledScript -PathType Leaf) { Remove-Item -LiteralPath $InstalledScript -Force }
        Write-Host ("Installed copy removed from {0} (if any)." -f $InstallDir)
    }
}

# -- dispatch ----------------------------------------------------------------
$selected = @($Install, $Uninstall, $Refresh | Where-Object { $_ }).Count
if ($selected -gt 1) {
    throw "Choose exactly one action: -Install, -Uninstall, or -Refresh."
}

if ($Install) {
    Invoke-Install -Port $Port -TaskName $TaskName
}
elseif ($Uninstall) {
    Invoke-Uninstall -Port $Port -TaskName $TaskName
}
elseif ($Refresh) {
    Invoke-Refresh -Port $Port
}
else {
    Write-Host ("credo-peer-lan-winproxy.ps1 v{0} - WSL2 portproxy + firewall allowlist for the credo LAN relay" -f $ScriptVersion)
    Write-Host ""
    Write-Host "Usage (run elevated for -Install / -Uninstall / -Refresh; add -DryRun to only print):"
    Write-Host "  -Install    [-Port N] [-TaskName name] [-AllowFile path]   one-time setup"
    Write-Host "  -Uninstall  [-Port N] [-TaskName name]                     remove everything"
    Write-Host "  -Refresh    [-Port N] [-AllowFile path]                    apply the allowlist + portproxy"
    Write-Host ""
    Write-Host "Port MUST match listen_port in ~/.claude/credo/peer-lan.json (default 48610)."
}

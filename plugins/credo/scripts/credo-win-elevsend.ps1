<#
.SYNOPSIS
  Elevated sender helper of the credo WSL <-> Windows peer bridge (credo item #196).

.DESCRIPTION
  A Claude Code session that runs elevated (as administrator) creates its inbox pipe
  \\.\pipe\LOCAL\cc-msg-<32 hex> with the default DACL of an elevated token: owner
  Administrators, full access for Administrators and SYSTEM, only READ for Everyone. The
  bridge's PowerShell half is started over WSL interop and is normally NOT elevated, so
  Windows denies it write access to such an inbox.

  This helper runs elevated in the user's interactive logon (a scheduled task without a
  trigger, started on demand by the bridge with `schtasks /Run`, no UAC prompt after the
  one-time -Install). It never runs permanently: it starts only while a bridge is alive
  (the bridge's PowerShell half keeps %LOCALAPPDATA%\credo\win-bridge-alive.json with
  its pid and creation time), and it exits after IdleMinutes without a request or as
  soon as that bridge is gone. With credo removed nothing starts it any more, and a
  manual start exits at once without opening the pipe. It serves ONE named pipe, LOCAL\credo-elevsend-<user SID>, whose DACL lets
  only this user (plus Administrators and SYSTEM) connect. A request is one JSON line
    {"v":1,"pipe":"LOCAL\\cc-msg-<32 hex>","data":"<base64>"}
  and the helper writes the bytes unchanged into that inbox pipe, then answers one line
    {"ok":true} or {"ok":false,"err":"..."}.
  The bytes already carry the auth line built by the bridge; the helper never parses,
  logs or stores them. It only writes to a pipe that matches ^LOCAL\cc-msg-[0-9a-f]{32}$
  AND belongs to a live, real (not a credo mirror) session descriptor of this user.

  SECURITY: the elevated task never runs a script from a user-writable location.
  -Install copies this script to %ProgramData%\credo\ with an admin-only write ACL and
  registers the task to run THAT copy. The client (the bridge) checks that the helper
  pipe is owned by Administrators before it sends, so a pipe squatted by a non-elevated
  process is never trusted. Granting the user's own non-elevated processes this send
  path into elevated sessions is an explicit owner decision (credo item #196).

.PARAMETER Install
  One-time setup (REQUIRES an elevated PowerShell): copy this script to
  %ProgramData%\credo, register the task (TaskName) and start it. Idempotent.

.PARAMETER Uninstall
  Stop and remove the task and the installed copy (REQUIRES an elevated PowerShell).

.PARAMETER Serve
  Run the helper (what the task runs; refuses to run without elevation).

.PARAMETER DryRun
  With -Install / -Uninstall: change nothing, print the plan.

.EXAMPLE
  # from WSL (one UAC prompt):
  credo-win-bridge.py elevsend-install
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Serve,
    [switch]$DryRun,
    [string]$TaskName = 'credo-win-elevsend',
    [string]$ResultFile = '',
    [int]$IdleMinutes = 5
)

$ErrorActionPreference = 'Stop'

# Bump by hand whenever this script changes: `credo-win-bridge.py status` compares it
# with the installed copy and asks for one re-install when that is older.
$ScriptVersion = 1

$script:ElevUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:ElevMaxRequest = 6MB
$script:ElevInstallDir = Join-Path $env:ProgramData 'credo'
$script:ElevInstalled = Join-Path $script:ElevInstallDir 'credo-win-elevsend.ps1'

# --- pure helpers (shared rules with credo-win-common.ps1, kept here so the elevated
# --- copy depends on no user-writable file) ------------------------------------------

function Get-ElevSendPipeName([string]$Sid) {
    return ('LOCAL\credo-elevsend-' + $Sid)
}

function Test-ElevSendTarget([string]$Name) {
    return ($null -ne $Name -and $Name -cmatch '^LOCAL\\cc-msg-[0-9a-f]{32}$')
}

function ConvertFrom-ElevSendRequest([string]$Line) {
    # @{ Pipe; Data } of a valid request line, or @{ Err } why it is refused
    if ([string]::IsNullOrEmpty($Line) -or $Line.Length -gt $script:ElevMaxRequest) { return @{ Err = 'empty or too large request'; Pipe = $null; Data = $null } }
    try { $o = $Line | ConvertFrom-Json } catch { return @{ Err = 'request is not JSON'; Pipe = $null; Data = $null } }
    if ($null -eq $o -or $o -isnot [System.Management.Automation.PSCustomObject]) { return @{ Err = 'request is not an object'; Pipe = $null; Data = $null } }
    $v = $o.PSObject.Properties['v']
    if ($null -eq $v -or [string]$v.Value -ne '1') { return @{ Err = 'unsupported request version'; Pipe = $null; Data = $null } }
    $p = $o.PSObject.Properties['pipe']
    if ($null -eq $p -or $p.Value -isnot [string] -or -not (Test-ElevSendTarget $p.Value)) { return @{ Err = 'target is not a Claude Code inbox pipe'; Pipe = $null; Data = $null } }
    $d = $o.PSObject.Properties['data']
    if ($null -eq $d -or $d.Value -isnot [string]) { return @{ Err = 'no data'; Pipe = $null; Data = $null } }
    try { $bytes = [Convert]::FromBase64String($d.Value) } catch { return @{ Err = 'data is not base64'; Pipe = $null; Data = $null } }
    if ($bytes.Length -eq 0) { return @{ Err = 'no data'; Pipe = $null; Data = $null } }
    return @{ Pipe = [string]$p.Value; Data = $bytes; Err = $null }
}

function Get-ElevSendProcessFt([long]$ProcessId) {
    if ($ProcessId -le 0) { return $null }
    try {
        $pr = [System.Diagnostics.Process]::GetProcessById([int]$ProcessId)
        try { return [string]$pr.StartTime.ToFileTimeUtc() } finally { $pr.Dispose() }
    } catch { return $null }
}

function Test-ElevSendLiveSession([string]$SessDir, [string]$Name) {
    # true when a live REAL session descriptor (canonical <pid>.json, no credo mirror
    # marker, pid alive with its recorded creation time) names this inbox pipe
    if (-not (Test-Path -LiteralPath $SessDir)) { return $false }
    foreach ($f in [System.IO.Directory]::GetFiles($SessDir, '*.json')) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($f)
        if ($base -notmatch '^[1-9][0-9]{0,9}$') { continue }
        try { $o = Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
        if ($null -eq $o) { continue }
        $mark = $false
        foreach ($k in 'credoWinBridge', 'credoPeerLan', 'credoPeerBridge') {
            $pp = $o.PSObject.Properties[$k]
            if ($null -ne $pp -and $pp.Value -eq $true) { $mark = $true }
        }
        if ($mark) { continue }
        $pidp = $o.PSObject.Properties['pid']
        if ($null -eq $pidp -or [string]$pidp.Value -ne $base) { continue }
        $msp = $o.PSObject.Properties['messagingSocketPath']
        if ($null -eq $msp -or $msp.Value -isnot [string]) { continue }
        $m = [regex]::Match($msp.Value, '^[\\/]{2}[.?][\\/]pipe[\\/]LOCAL[\\/]([^\\/]+)$', 'IgnoreCase')
        if (-not $m.Success -or ('LOCAL\' + $m.Groups[1].Value.ToLowerInvariant()) -cne $Name) { continue }
        $want = $o.PSObject.Properties['procStartFt']
        if ($null -eq $want) { $want = $o.PSObject.Properties['procStart'] }
        $ft = Get-ElevSendProcessFt ([long]$base)
        if ($null -eq $ft) { continue }
        if ($null -ne $want -and [string]$want.Value -ne $ft) { continue }
        return $true
    }
    return $false
}

function Get-ElevSendAliveFile {
    return (Join-Path $env:LOCALAPPDATA 'credo\win-bridge-alive.json')
}

function Test-ElevSendBridgeAlive([string]$Path) {
    # true while the bridge that wrote the alive file runs (pid alive with the recorded
    # creation time); a missing, unreadable or stale file means credo's bridge is gone
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { $o = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return $false }
    if ($null -eq $o) { return $false }
    $pp = $o.PSObject.Properties['pid']
    $fp = $o.PSObject.Properties['ft']
    if ($null -eq $pp -or $null -eq $fp) { return $false }
    $procId = 0L
    if (-not [long]::TryParse([string]$pp.Value, [ref]$procId)) { return $false }
    $ft = Get-ElevSendProcessFt $procId
    return ($null -ne $ft -and $ft -eq [string]$fp.Value)
}

function Test-ElevSendShouldExit([bool]$BridgeAlive, [DateTime]$LastActivity, [DateTime]$Now, [int]$IdleMin) {
    # the helper never lingers: gone bridge or idle time used up -> exit
    return ((-not $BridgeAlive) -or ($Now - $LastActivity).TotalMinutes -ge $IdleMin)
}

function New-ElevSendReply([bool]$Ok, [string]$Err) {
    $o = [ordered]@{ ok = $Ok; v = $ScriptVersion }
    if (-not $Ok) { $o.err = $Err }
    return $script:ElevUtf8.GetBytes(($o | ConvertTo-Json -Compress) + "`n")
}

function Test-ElevSendAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object System.Security.Principal.WindowsPrincipal $id).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- serve ---------------------------------------------------------------------------

function Write-ElevSendLog([string]$Text) {
    # admin-only folder; never a payload or token, only what happened
    try {
        $p = Join-Path $script:ElevInstallDir 'win-elevsend.log'
        if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 512KB) {
            Move-Item -LiteralPath $p -Destination ($p + '.1') -Force
        }
        [System.IO.File]::AppendAllText($p, ((Get-Date).ToString('s') + ' ' + $Text + "`r`n"), $script:ElevUtf8)
    } catch {}
}

function New-ElevSendServer([string]$Name, [System.Security.Principal.SecurityIdentifier]$User) {
    $sec = New-Object System.IO.Pipes.PipeSecurity
    $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $sec.SetOwner($admins)
    $sec.SetAccessRuleProtection($true, $false)
    $sec.AddAccessRule((New-Object System.IO.Pipes.PipeAccessRule($admins, 'FullControl', 'Allow')))
    $sec.AddAccessRule((New-Object System.IO.Pipes.PipeAccessRule($system, 'FullControl', 'Allow')))
    $sec.AddAccessRule((New-Object System.IO.Pipes.PipeAccessRule($User, 'ReadWrite, Synchronize', 'Allow')))
    return New-Object System.IO.Pipes.NamedPipeServerStream($Name, [System.IO.Pipes.PipeDirection]::InOut, 4,
        [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous, 65536, 65536, $sec)
}

function Read-ElevSendLine($Stream, [int]$TimeoutMs) {
    # one request line (up to the newline), $null on timeout, EOF first or oversize
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 65536
    $end = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        $left = [int]($end - [DateTime]::UtcNow).TotalMilliseconds
        if ($left -le 0) { return $null }
        $t = $Stream.ReadAsync($buf, 0, $buf.Length)
        if (-not $t.Wait($left)) { return $null }
        $n = $t.Result
        if ($n -le 0) { return $null }
        $ms.Write($buf, 0, $n)
        if ($ms.Length -gt $script:ElevMaxRequest) { return $null }
        if ([Array]::IndexOf($buf, [byte]10, 0, $n) -ge 0) {
            $all = $ms.ToArray()
            $i = [Array]::IndexOf($all, [byte]10)
            return $script:ElevUtf8.GetString($all, 0, $i)
        }
    }
}

function Send-ElevSendTarget([string]$Name, [byte[]]$Data) {
    # write the bytes into the inbox pipe; returns '' on success, else the reason
    $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Name, [System.IO.Pipes.PipeDirection]::InOut,
        [System.IO.Pipes.PipeOptions]::Asynchronous)
    try {
        try { $c.Connect(1500) } catch { return ('connect failed: ' + $_.Exception.InnerException.Message) }
        try {
            $w = $c.WriteAsync($Data, 0, $Data.Length)
            if (-not $w.Wait(1500)) { return 'write timed out' }
            $c.Flush()
        } catch { return ('write failed: ' + $_.Exception.Message) }
        # close shortly after the write, like a Claude Code sender
        Start-Sleep -Milliseconds 300
        return ''
    } finally {
        [Array]::Clear($Data, 0, $Data.Length)
        $c.Dispose()
    }
}

function Invoke-ElevSendServe {
    if (-not (Test-ElevSendAdmin)) { Write-Host 'credo-win-elevsend: -Serve needs elevation (run it through its scheduled task)'; exit 2 }
    $alive = Get-ElevSendAliveFile
    if (-not (Test-ElevSendBridgeAlive $alive)) {
        # credo's bridge is not running (or credo was removed): never open the pipe
        Write-ElevSendLog 'no live credo bridge on this machine, exiting without serving'
        exit 0
    }
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $name = Get-ElevSendPipeName $user.Value
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, ('Local\credo-elevsend-' + $user.Value), [ref]$created)
    if (-not $created) { Write-ElevSendLog 'another helper is running, exiting'; exit 0 }
    $sessDir = Join-Path $env:USERPROFILE '.claude\sessions'
    Write-ElevSendLog ('helper v' + $ScriptVersion + ' serving (pid ' + $PID + ')')
    $last = [DateTime]::UtcNow
    try {
        while ($true) {
            try { $srv = New-ElevSendServer $name $user } catch {
                Write-ElevSendLog ('cannot create the helper pipe: ' + $_.Exception.Message)
                return
            }
            try {
                $wait = $srv.WaitForConnectionAsync()
                $stop = $false
                while (-not $wait.Wait(15000)) {
                    if (Test-ElevSendShouldExit (Test-ElevSendBridgeAlive $alive) $last ([DateTime]::UtcNow) $IdleMinutes) { $stop = $true; break }
                }
                if ($stop) { Write-ElevSendLog 'idle or no live bridge any more, exiting'; return }
                $last = [DateTime]::UtcNow
                $line = Read-ElevSendLine $srv 3000
                if ($null -eq $line) { continue }
                $req = ConvertFrom-ElevSendRequest $line
                $line = $null
                if ($req.Err) { $reply = New-ElevSendReply $false $req.Err }
                elseif (-not (Test-ElevSendLiveSession $sessDir $req.Pipe)) {
                    [Array]::Clear($req.Data, 0, $req.Data.Length)
                    $reply = New-ElevSendReply $false 'no live session owns that inbox pipe'
                } else {
                    $err = Send-ElevSendTarget $req.Pipe $req.Data
                    if ($err) { Write-ElevSendLog ('send failed: ' + $err) }
                    $reply = New-ElevSendReply ($err -eq '') $err
                }
                try { $srv.Write($reply, 0, $reply.Length); $srv.Flush(); $srv.WaitForPipeDrain() } catch {}
            } catch {
                Write-ElevSendLog ('request failed: ' + $_.Exception.Message)
            } finally {
                $srv.Dispose()
            }
        }
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

# --- install / uninstall ------------------------------------------------------------

function Write-ElevSendResult([string]$Line) {
    Write-Host $Line
    if (-not [string]::IsNullOrWhiteSpace($ResultFile)) { Set-Content -LiteralPath $ResultFile -Value $Line -Encoding UTF8 }
}

function Set-ElevSendAdminOnlyAcl([string]$Path, [bool]$IsDir) {
    # owner Administrators, inheritance cut: Administrators + SYSTEM full, Users read/execute
    $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    if ($IsDir) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]::None
    }
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $acl.SetOwner($admins)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, 'FullControl', $inherit, $prop, $allow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, 'FullControl', $inherit, $prop, $allow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($users, 'ReadAndExecute', $inherit, $prop, $allow)))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Invoke-ElevSendInstall {
    if (-not $DryRun -and -not (Test-ElevSendAdmin)) { throw '-Install needs an elevated PowerShell (Run as administrator).' }
    if (Test-Path -LiteralPath $script:ElevInstallDir) {
        if ((Get-Item -LiteralPath $script:ElevInstallDir -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw ($script:ElevInstallDir + ' is a junction/symlink - refusing to install there.')
        }
    }
    $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $arg = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Serve' -f $script:ElevInstalled
    if ($DryRun) {
        Write-Host ('DRYRUN: would copy {0} -> {1} (admin-only write ACL, v{2})' -f $PSCommandPath, $script:ElevInstalled, $ScriptVersion)
        Write-Host ('DRYRUN: would register task {0}: powershell.exe {1} (user {2}, interactive logon, highest privileges, no trigger: started on demand only)' -f $TaskName, $arg, $user)
        return
    }
    if (-not (Test-Path -LiteralPath $script:ElevInstallDir)) { New-Item -ItemType Directory -Path $script:ElevInstallDir | Out-Null }
    Set-ElevSendAdminOnlyAcl $script:ElevInstallDir $true
    $src = $PSCommandPath
    if ($src -ne $script:ElevInstalled) {
        if (Test-Path -LiteralPath $script:ElevInstalled) { Remove-Item -LiteralPath $script:ElevInstalled -Force }
        Copy-Item -LiteralPath $src -Destination $script:ElevInstalled
    }
    Set-ElevSendAdminOnlyAcl $script:ElevInstalled $false
    $old = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($old) { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    # Interactive: runs in the user's own logon session, so LOCAL\ pipe names match the
    # sessions' inboxes; Highest: the elevated token, without a UAC prompt per start
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    # no trigger: the bridge starts it on demand; the helper exits by itself when idle
    # (the 12 h limit is only a backstop)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 12)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null
}

function Invoke-ElevSendUninstall {
    if ($DryRun) { Write-Host ('DRYRUN: would stop and remove task {0} and {1}' -f $TaskName, $script:ElevInstalled); return }
    if (-not (Test-ElevSendAdmin)) { throw '-Uninstall needs an elevated PowerShell (Run as administrator).' }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    if (Test-Path -LiteralPath $script:ElevInstalled -PathType Leaf) { Remove-Item -LiteralPath $script:ElevInstalled -Force }
}

# --- dispatch (skipped when dot-sourced, e.g. by the tests) ----------------------------
if ($MyInvocation.InvocationName -ne '.') {
    if (@($Install, $Uninstall, $Serve | Where-Object { $_ }).Count -gt 1) { throw 'Choose one action: -Install, -Uninstall or -Serve.' }
    if ($Install) {
        try {
            Invoke-ElevSendInstall
            if ($DryRun) { Write-Host '-Install DRYRUN finished: nothing was changed.' }
            else { Write-ElevSendResult ('-Install OK: helper v{0} installed, task ''{1}'' (started on demand by the bridge).' -f $ScriptVersion, $TaskName) }
        } catch { Write-ElevSendResult ('-Install FAILED: ' + $_.Exception.Message); exit 1 }
    } elseif ($Uninstall) {
        try { Invoke-ElevSendUninstall; if (-not $DryRun) { Write-ElevSendResult ('-Uninstall OK: task ''{0}'' and the installed copy removed.' -f $TaskName) } }
        catch { Write-ElevSendResult ('-Uninstall FAILED: ' + $_.Exception.Message); exit 1 }
    } elseif ($Serve) {
        Invoke-ElevSendServe
    } else {
        Write-Host ('credo-win-elevsend.ps1 v{0} - elevated sender helper of the credo WSL <-> Windows bridge' -f $ScriptVersion)
        Write-Host 'Usage: -Install | -Uninstall (elevated, add -DryRun to only print) | -Serve (the task runs it)'
    }
}

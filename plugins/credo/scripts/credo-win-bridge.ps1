<#
.SYNOPSIS
  Windows half of the credo WSL <-> Windows peer bridge (credo item #183).

.DESCRIPTION
  Started by credo-win-bridge.py (WSL) through WSL interop, never by hand. Talks to it
  over stdin/stdout, one JSON object per line (protocol: see credo-win-bridge.py).

  - list:    the live real Windows Claude Code sessions (descriptor fields only; key
             files are never read for this).
  - send:    write a message into a Windows session's pipe, after the auth line built
             from that session's own key file. The token is read here, on Windows, and
             only ever written into that pipe.
  - publish: keep one mirror per offered WSL session in %USERPROFILE%\.claude\sessions
             (holder process, named pipe, descriptor, own key file with a random token,
             marker credoWinBridge). Connections to a mirror pipe must start with the
             auth line carrying that token; the line is checked (constant time) and
             stripped, the rest goes to WSL as {"op":"msg"}.
  - quit / stdin EOF: remove every mirror of this run (only files with our marker and
             our owner pid, only our own holders) and exit.

  Nothing to install: Windows PowerShell 5.1 and .NET Framework 4.6+ only.

.PARAMETER Mode
  Bridge (the only mode).
#>
param(
    [string]$Mode = 'Bridge'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'credo-win-common.ps1')

$script:Out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object System.Text.UTF8Encoding($false)))
$script:Out.AutoFlush = $true
$script:Out.NewLine = "`n"

function Send-BridgeEvent($Obj) {
    $script:Out.WriteLine(($Obj | ConvertTo-Json -Compress -Depth 6))
}

function Send-BridgeLog([string]$Text) {
    Send-BridgeEvent ([ordered]@{ op = 'log'; text = $Text })
}

function Get-BridgeSessionList($Hub) {
    $keep = 'pid', 'sessionId', 'cwd', 'name', 'nameSource', 'status', 'version', 'peerProtocol', 'peerFeatures',
            'kind', 'entrypoint', 'pidDomain', 'messagingSocketPath', 'updatedAt', 'statusUpdatedAt', 'startedAt'
    $out = @()
    foreach ($o in (Get-CredoSessions $Hub.SessDir)) {
        $e = [ordered]@{}
        foreach ($k in $keep) {
            $v = Get-CredoProp $o $k
            if ($null -ne $v) { $e[$k] = $v }
        }
        $out += ,$e
    }
    return ,$out
}

function Sync-BridgeMirrors($Hub, $Sessions) {
    $want = @{}
    foreach ($s in @($Sessions)) {
        if ($null -eq $s) { continue }
        $key = [string](Get-CredoProp $s 'key')
        if ($key -notmatch '^[A-Za-z0-9._-]{1,128}$') { continue }
        $want[$key] = @{
            sessionId    = $key
            name         = [string](Get-CredoProp $s 'name')
            status       = [string](Get-CredoProp $s 'status')
            cwd          = [string](Get-CredoProp $s 'cwd')
            version      = [string](Get-CredoProp $s 'version')
            peerProtocol = (Get-CredoProp $s 'peerProtocol')
            peerFeatures = @(Get-CredoProp $s 'peerFeatures')
        }
    }
    foreach ($k in @($Hub.Mirrors.Keys)) { if (-not $want.ContainsKey($k)) { Remove-CredoMirror $Hub $k } }
    foreach ($k in $want.Keys) {
        $m = $Hub.Mirrors[$k]
        if ($null -eq $m) {
            $m = New-CredoMirror $Hub $k $want[$k] @{ credoWinBridgeFrom = 'wsl' }
            if ($null -eq $m) { Send-BridgeLog ('could not create the Windows mirror of ' + $want[$k].name) }
        } else {
            Update-CredoMirror $Hub $m $want[$k]
        }
    }
    $list = @()
    foreach ($m in $Hub.Mirrors.Values) { $list += ,([ordered]@{ key = $m.Key; pipe = $m.PipePath }) }
    Send-BridgeEvent ([ordered]@{ op = 'published'; mirrors = $list })
}

function Invoke-BridgeCommand($Hub, [string]$Line) {
    try { $cmd = $Line | ConvertFrom-Json } catch { Send-BridgeLog 'unparseable command ignored'; return $true }
    $op = [string](Get-CredoProp $cmd 'op')
    switch ($op) {
        'list' {
            Send-BridgeEvent ([ordered]@{ op = 'list'; id = (Get-CredoProp $cmd 'id'); sessions = (Get-BridgeSessionList $Hub) })
        }
        'send' {
            $id = Get-CredoProp $cmd 'id'
            $data = $null
            try { $data = [Convert]::FromBase64String([string](Get-CredoProp $cmd 'data')) } catch {}
            $tpid = Get-CredoProp $cmd 'pid'
            if ($null -eq $data -or $data.Length -eq 0 -or $null -eq $tpid) {
                Send-BridgeEvent ([ordered]@{ op = 'sent'; id = $id; ok = $false; err = 'bad send command' })
            } else {
                Start-CredoSend $Hub ([long]$tpid) ([string](Get-CredoProp $cmd 'pipe')) $data $id {
                    param($i, $ok, $err)
                    Send-BridgeEvent ([ordered]@{ op = 'sent'; id = $i; ok = $ok; err = $err })
                }
            }
        }
        'publish' { Sync-BridgeMirrors $Hub (Get-CredoProp $cmd 'sessions') }
        'quit' { return $false }
        default { Send-BridgeLog ('unknown op ' + $op) }
    }
    return $true
}

function Start-Bridge {
    $sessDir = Get-CredoSessionsDir
    if (-not (Test-Path -LiteralPath $sessDir)) { [void](New-Item -ItemType Directory -Path $sessDir -Force) }
    $hub = New-CredoHub $sessDir 'credoWinBridge' {
        param($mirror, [byte[]]$data)
        Send-BridgeEvent ([ordered]@{ op = 'msg'; key = $mirror.Key; data = [Convert]::ToBase64String($data) })
    } { param($t) Send-BridgeLog $t }
    Remove-CredoStaleMirrors $hub
    Start-CredoWatchdog $hub
    $in = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
    Send-BridgeEvent ([ordered]@{ op = 'ready'; pid = $PID; host = [System.Net.Dns]::GetHostName(); user = $env:USERNAME;
                                  pidDomain = $hub.PidDomain; sessionsDir = $sessDir })
    $lineTask = $in.ReadLineAsync()
    $nextCheck = [DateTime]::UtcNow.AddSeconds(10)
    try {
        while ($true) {
            $tasks = Get-CredoHubTasks $hub
            [void]$tasks.Add($lineTask)
            Wait-CredoTasks $tasks 250
            if ($lineTask.IsCompleted) {
                if ($lineTask.IsFaulted -or $null -eq $lineTask.Result) { break }
                $line = $lineTask.Result
                if ($line.Trim()) { if (-not (Invoke-BridgeCommand $hub $line)) { break } }
                $lineTask = $in.ReadLineAsync()
            }
            Invoke-CredoHubPoll $hub
            if ([DateTime]::UtcNow -gt $nextCheck) {
                $nextCheck = [DateTime]::UtcNow.AddSeconds(10)
                Test-CredoHolders $hub
            }
        }
    } finally {
        Remove-CredoAllMirrors $hub
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Mode -ne 'Bridge') { [Console]::Error.WriteLine('unknown mode ' + $Mode); exit 2 }
    Start-Bridge
}

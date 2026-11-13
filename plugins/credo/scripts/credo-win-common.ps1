<#
.SYNOPSIS
  Shared Windows-side helpers of the credo peer bridge (credo-win-bridge.ps1, started
  from WSL) and the native Windows LAN relay (credo-peer-lan-win.ps1). Dot-source it.

.DESCRIPTION
  Windows PowerShell 5.1 and .NET Framework 4.6+ only (both ship with Windows 10/11);
  nothing to install, no Add-Type, no admin rights.

  Native Windows Claude Code keeps its session registry in %USERPROFILE%\.claude\sessions:
    <pid>.json                 descriptor; messagingSocketPath is a named pipe
                               \\.\pipe\LOCAL\cc-msg-<32 hex>; procStart is the process
                               creation time as a FILETIME (UTC) string
    <pid>.<sha256>.key         {"peerToken":"<32 hex>","procStartFt":"<FILETIME>",
                               "pidDomain":"win32:<host>"}; sha256 = hex of
                               "\\.\pipe\" + the pipe name with A-Z lowercased
  A Windows inbox only accepts a connection whose FIRST line is
  {"type":"auth","token":"<that session's peerToken>"}; a sender reads the target's key
  file. A sender checks that the key file's pid is alive with that creation time and
  that the descriptor's pid is alive with procStart; it does not check which process
  serves the pipe.

  A mirror (a session of another side shown here) therefore needs:
    - a HOLDER: a tiny live process (waitfor.exe on a random signal name) whose pid and
      creation time go into the descriptor and the key file,
    - named pipe server instances on a random LOCAL\cc-msg-<32 hex> name, served by
      this PowerShell process,
    - its own key file with a random token; every connection must start with the auth
      line carrying that token (constant-time compare), which is stripped before the
      message is handed on.
  Every mirror file carries a marker key (credoWinBridge or credoPeerLan) plus the
  owner process (pid + creation time), so cleanup only ever removes this tool's own
  files and kills only its own holders (pid + creation time + image name checked).

  SECRETS: a token is read from a key file only to write it into the target pipe; it is
  never logged, printed or sent anywhere else.
#>

Set-StrictMode -Version 2.0

$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:MaxMessage = 4MB
$script:ConnTimeoutMs = 5000
$script:ListenersPerMirror = 2
$script:MaxMirrors = 128

function Get-CredoSessionsDir {
    if ($env:CREDO_WIN_SESSIONS_DIR) { return $env:CREDO_WIN_SESSIONS_DIR }
    return (Join-Path $env:USERPROFILE ".claude\sessions")
}

function Get-CredoNowMs {
    return [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
}

# --- names, hashes, tokens ---------------------------------------------------------

function Get-CredoPipeName([string]$Path) {
    # .NET pipe name ("LOCAL\cc-msg-...") of a messagingSocketPath, $null when not a pipe
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $m = [regex]::Match($Path, '^[\\/]{2}[.?][\\/]pipe[\\/](?:(LOCAL)[\\/])?([^\\/]+)$', 'IgnoreCase')
    if (-not $m.Success) { return $null }
    $n = $m.Groups[2].Value
    if ($n -eq '.' -or $n -eq '..' -or $n -match '[. ]$') { return $null }
    if ($Path.StartsWith('\\?\') -and $Path.Contains('/')) { return $null }
    if ($m.Groups[1].Success) { return ('LOCAL\' + $n) }
    return $n
}

function Test-CredoCcPipeName([string]$Name) {
    return ($null -ne $Name -and $Name -match '^LOCAL\\cc-msg-[0-9a-f]{32}$')
}

function Get-CredoCanonicalPipePath([string]$Path) {
    $n = Get-CredoPipeName $Path
    if ($null -eq $n) { return $null }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $n.ToCharArray()) {
        if ($ch -ge [char]'A' -and $ch -le [char]'Z') { [void]$sb.Append([char]([int]$ch + 32)) }
        else { [void]$sb.Append($ch) }
    }
    return ('\\.\pipe\' + $sb.ToString())
}

function Get-CredoSha256Hex([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash($script:Utf8.GetBytes($Text)) } finally { $sha.Dispose() }
    return (-join ($h | ForEach-Object { $_.ToString('x2') }))
}

function Get-CredoKeyFileName([long]$ProcessId, [string]$PipePath) {
    $c = Get-CredoCanonicalPipePath $PipePath
    if ($null -eq $c) { return $null }
    return ('{0}.{1}.key' -f $ProcessId, (Get-CredoSha256Hex $c))
}

function New-CredoRandomHex([int]$Bytes) {
    $b = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return (-join ($b | ForEach-Object { $_.ToString('x2') }))
}

function New-CredoAuthLineBytes([string]$Token) {
    if ($Token -cnotmatch '^[0-9a-f]{32}$') { throw 'invalid token' }
    return $script:Utf8.GetBytes('{"type":"auth","token":"' + $Token + '"}' + "`n")
}

function Test-CredoTokenEqual([string]$A, [string]$B) {
    # constant time for equal-length inputs; any length difference is a mismatch
    if ($null -eq $A -or $null -eq $B) { return $false }
    $x = $script:Utf8.GetBytes($A)
    $y = $script:Utf8.GetBytes($B)
    $diff = $x.Length -bxor $y.Length
    $n = [Math]::Max($x.Length, $y.Length)
    for ($i = 0; $i -lt $n; $i++) {
        $a = if ($i -lt $x.Length) { $x[$i] } else { 0 }
        $b = if ($i -lt $y.Length) { $y[$i] } else { 0 }
        $diff = $diff -bor ($a -bxor $b)
    }
    return ($diff -eq 0)
}

function Get-CredoAuthToken([byte[]]$Line) {
    # token of an auth line, '' for an auth line without a string token, $null otherwise
    try { $o = $script:Utf8.GetString($Line).Trim() | ConvertFrom-Json } catch { return $null }
    if ($null -eq $o -or $o -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $t = $o.PSObject.Properties['type']
    if ($null -eq $t -or $t.Value -cne 'auth') { return $null }
    $k = $o.PSObject.Properties['token']
    if ($null -eq $k -or $k.Value -isnot [string]) { return '' }
    return [string]$k.Value
}

function Get-CredoIndexOfNewline([byte[]]$Data, [int]$Start) {
    for ($i = $Start; $i -lt $Data.Length; $i++) { if ($Data[$i] -eq 10) { return $i } }
    return -1
}

function Split-CredoBytes([byte[]]$Data, [int]$Start, [int]$Count) {
    $out = New-Object byte[] $Count
    if ($Count -gt 0) { [Array]::Copy($Data, $Start, $out, 0, $Count) }
    return ,$out
}

# --- processes -----------------------------------------------------------------

function Get-CredoProcessFt([long]$ProcessId) {
    # creation time of a live process as a FILETIME string (the procStart form native
    # Windows Claude Code writes), $null when the process is gone or unreadable
    if ($ProcessId -le 0) { return $null }
    try {
        $p = [System.Diagnostics.Process]::GetProcessById([int]$ProcessId)
        try { return [string]$p.StartTime.ToFileTimeUtc() } finally { $p.Dispose() }
    } catch { return $null }
}

function Get-CredoProcessName([long]$ProcessId) {
    try {
        $p = [System.Diagnostics.Process]::GetProcessById([int]$ProcessId)
        try { return $p.ProcessName } finally { $p.Dispose() }
    } catch { return $null }
}

function Start-CredoHolder {
    # one tiny live process per mirror: waitfor.exe on a random signal (never signalled),
    # hidden, no window; falls back to a sleeping powershell.exe when waitfor is missing
    $exe = Join-Path $env:SystemRoot 'System32\waitfor.exe'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if (Test-Path -LiteralPath $exe) {
        $psi.FileName = $exe
        $psi.Arguments = 'credo' + (New-CredoRandomHex 16)
    } else {
        $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments = '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 2147483'
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}

function Stop-CredoHolder([long]$ProcessId, [string]$Ft) {
    # kill only when pid, creation time AND image name prove it is one of our holders
    if ($ProcessId -le 0 -or [string]::IsNullOrEmpty($Ft)) { return $false }
    if ((Get-CredoProcessFt $ProcessId) -ne $Ft) { return $false }
    $name = Get-CredoProcessName $ProcessId
    if ($name -ne 'waitfor' -and $name -ne 'powershell') { return $false }
    try {
        $p = [System.Diagnostics.Process]::GetProcessById([int]$ProcessId)
        try { $p.Kill(); [void]$p.WaitForExit(3000) } finally { $p.Dispose() }
        return $true
    } catch { return $false }
}

# --- files -----------------------------------------------------------------------

function Write-CredoFileAtomic([string]$Path, [string]$Text) {
    $tmp = $Path + '.credo.' + $PID + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Text, $script:Utf8)
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, $null) }
    else { [System.IO.File]::Move($tmp, $Path) }
}

function Read-CredoJsonFile([string]$Path) {
    try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Get-CredoProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Test-CredoMirrorFile($Obj) {
    # a descriptor written by a credo mirror (WSL bridge or native LAN relay)
    return ((Get-CredoProp $Obj 'credoWinBridge') -eq $true -or (Get-CredoProp $Obj 'credoPeerLan') -eq $true -or
            (Get-CredoProp $Obj 'credoPeerBridge') -eq $true)
}

function Get-CredoSessions([string]$SessDir) {
    # live REAL Windows sessions: a canonical <pid>.json, no mirror marker, a Claude Code
    # pipe address, pid alive with the recorded creation time
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $SessDir)) { return ,$out }
    foreach ($f in [System.IO.Directory]::GetFiles($SessDir, '*.json')) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($f)
        if ($base -notmatch '^[1-9][0-9]{0,9}$') { continue }
        $o = Read-CredoJsonFile $f
        if ($null -eq $o -or (Test-CredoMirrorFile $o)) { continue }
        $procId = Get-CredoProp $o 'pid'
        if ($null -eq $procId -or [string]$procId -ne $base) { continue }
        $name = Get-CredoPipeName ([string](Get-CredoProp $o 'messagingSocketPath'))
        if (-not (Test-CredoCcPipeName $name)) { continue }
        $want = Get-CredoProp $o 'procStartFt'
        if ($null -eq $want) { $want = Get-CredoProp $o 'procStart' }
        $ft = Get-CredoProcessFt ([long]$procId)
        if ($null -eq $ft -or ($null -ne $want -and [string]$want -ne $ft)) { continue }
        [void]$out.Add($o)
    }
    return ,$out
}

function Get-CredoPidDomain([string]$SessDir) {
    # pidDomain of the newest live real session (so mirrors count as local); fallback
    # win32:<lowercase host name>
    $best = $null
    foreach ($o in (Get-CredoSessions $SessDir)) {
        $d = Get-CredoProp $o 'pidDomain'
        if ($d -is [string] -and $d.StartsWith('win32:')) {
            $u = Get-CredoProp $o 'updatedAt'
            if ($null -eq $best -or [double]$u -gt [double]$best[0]) { $best = @($u, $d) }
        }
    }
    if ($null -ne $best) { return $best[1] }
    return ('win32:' + [System.Net.Dns]::GetHostName().ToLowerInvariant())
}

function Find-CredoToken([string]$SessDir, [long]$TargetPid, [string]$PipePath) {
    # the target inbox's peerToken from its key file (found by the pipe hash, the way a
    # Windows sender finds it; a live owner with matching creation time preferred)
    $c = Get-CredoCanonicalPipePath $PipePath
    if ($null -eq $c) { return $null }
    $suffix = '.' + (Get-CredoSha256Hex $c) + '.key'
    $cands = @()
    if (-not (Test-Path -LiteralPath $SessDir)) { return $null }
    foreach ($f in [System.IO.Directory]::GetFiles($SessDir, '*.key')) {
        $n = [System.IO.Path]::GetFileName($f)
        if (-not $n.EndsWith($suffix)) { continue }
        $m = [regex]::Match($n, '^([0-9]+)\.[0-9a-f]{64}\.key$')
        if ($m.Success) { $cands += ,@([long]$m.Groups[1].Value, $f) }
    }
    $best = $null
    $bestRank = -1
    foreach ($c2 in $cands) {
        $o = Read-CredoJsonFile $c2[1]
        $tok = Get-CredoProp $o 'peerToken'
        if ($tok -isnot [string] -or $tok -cnotmatch '^[0-9a-f]{32}$') { continue }
        $want = Get-CredoProp $o 'procStartFt'
        if ($null -eq $want) { $want = Get-CredoProp $o 'procStart' }
        $ft = Get-CredoProcessFt $c2[0]
        $rank = 0
        if ($null -ne $ft) { $rank = if ($null -eq $want) { 1 } elseif ([string]$want -eq $ft) { 2 } else { 0 } }
        if ($c2[0] -eq $TargetPid) { $rank += 1 }
        if ($rank -gt $bestRank) { $bestRank = $rank; $best = $tok }
    }
    return $best
}

# --- the hub: mirrors (pipe servers) and outgoing sends, polled from one thread ------

function New-CredoHub([string]$SessDir, [string]$Marker, [scriptblock]$OnMessage, [scriptblock]$OnLog) {
    $me = [System.Diagnostics.Process]::GetCurrentProcess()
    return @{
        SessDir   = $SessDir
        Marker    = $Marker
        OnMessage = $OnMessage
        OnLog     = $OnLog
        Mirrors   = @{}
        Conns     = New-Object System.Collections.ArrayList
        Sends     = New-Object System.Collections.ArrayList
        OwnerPid  = [long]$me.Id
        OwnerFt   = [string]$me.StartTime.ToFileTimeUtc()
        PidDomain = (Get-CredoPidDomain $SessDir)
    }
}

function Write-CredoHubLog($Hub, [string]$Text) {
    if ($null -ne $Hub.OnLog) { & $Hub.OnLog $Text }
}

function Add-CredoListener($Hub, $Mirror) {
    $srv = New-Object System.IO.Pipes.NamedPipeServerStream($Mirror.PipeName, [System.IO.Pipes.PipeDirection]::InOut,
        -1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous, 65536, 65536)
    [void]$Mirror.Waiting.Add(@{ Srv = $srv; Task = $srv.WaitForConnectionAsync() })
}

function New-CredoDescriptorJson($Hub, $Mirror) {
    $f = $Mirror.Fields
    $now = Get-CredoNowMs
    $d = [ordered]@{
        pid                 = $Mirror.HolderPid
        sessionId           = [string]$f['sessionId']
        cwd                 = [string]$f['cwd']
        startedAt           = $Mirror.StartedAt
        procStart           = $Mirror.HolderFt
        version             = [string]$f['version']
        peerProtocol        = 1
        peerFeatures        = @($f['peerFeatures'] | Where-Object { $_ -is [string] })
        kind                = 'interactive'
        entrypoint          = 'cli'
        pidDomain           = $Hub.PidDomain
        messagingSocketPath = $Mirror.PipePath
        name                = [string]$f['name']
        nameSource          = 'credo'
        nameSince           = $Mirror.StartedAt
        updatedAt           = $now
        status              = [string]$f['status']
        statusUpdatedAt     = $now
    }
    if ($f['peerProtocol'] -is [int] -or $f['peerProtocol'] -is [long]) { $d.peerProtocol = [int]$f['peerProtocol'] }
    if ([string]::IsNullOrEmpty($d.status)) { $d.status = 'idle' }
    $d[$Hub.Marker] = $true
    $d['credoOwnerPid'] = $Hub.OwnerPid
    $d['credoOwnerFt'] = $Hub.OwnerFt
    $d['credoHolderFt'] = $Mirror.HolderFt
    $d['credoKeyFile'] = $Mirror.KeyName
    if ($null -ne $Mirror.Extra) { foreach ($k in $Mirror.Extra.Keys) { $d[$k] = $Mirror.Extra[$k] } }
    $json = $d | ConvertTo-Json -Compress -Depth 4
    # PowerShell 5.1 turns an empty array into "", a one-element array into a scalar
    $feat = '"peerFeatures":' + (ConvertTo-CredoJsonArray $d.peerFeatures)
    return [regex]::Replace($json, '"peerFeatures":(\[[^\]]*\]|"[^"]*"|null)', { param($m) $feat })
}

function ConvertTo-CredoJsonArray($Items) {
    $parts = @()
    foreach ($i in @($Items)) { if ($i -is [string]) { $parts += (ConvertTo-Json -InputObject $i -Compress) } }
    return ('[' + ($parts -join ',') + ']')
}

function New-CredoMirror($Hub, [string]$Key, $Fields, $Extra) {
    if ($Hub.Mirrors.Count -ge $script:MaxMirrors) { return $null }
    $holder = Start-CredoHolder
    Start-Sleep -Milliseconds 30
    $hft = Get-CredoProcessFt $holder.Id
    if ($null -eq $hft) { return $null }
    $pipeName = 'LOCAL\cc-msg-' + (New-CredoRandomHex 16)
    $m = @{
        Key       = $Key
        Fields    = $Fields
        Extra     = $Extra
        HolderPid = [long]$holder.Id
        HolderFt  = $hft
        PipeName  = $pipeName
        PipePath  = '\\.\pipe\' + $pipeName
        Token     = (New-CredoRandomHex 16)
        Waiting   = New-Object System.Collections.ArrayList
        StartedAt = (Get-CredoNowMs)
    }
    $m.KeyName = Get-CredoKeyFileName $m.HolderPid $m.PipePath
    $m.KeyPath = Join-Path $Hub.SessDir $m.KeyName
    $m.DescPath = Join-Path $Hub.SessDir ('{0}.json' -f $m.HolderPid)
    $holder.Dispose()
    if ((Test-Path -LiteralPath $m.DescPath) -or (Test-Path -LiteralPath $m.KeyPath)) {
        # a file we do not own sits at this pid: never overwrite it
        [void](Stop-CredoHolder $m.HolderPid $m.HolderFt)
        return $null
    }
    try {
        for ($i = 0; $i -lt $script:ListenersPerMirror; $i++) { Add-CredoListener $Hub $m }
        # key file first, then the descriptor: once a session sees the descriptor, the
        # pipe and the key are there
        $keyJson = '{"peerToken":"' + $m.Token + '","procStartFt":"' + $m.HolderFt + '","pidDomain":' +
                   (ConvertTo-Json -InputObject ([string]$Hub.PidDomain) -Compress) + '}'
        Write-CredoFileAtomic $m.KeyPath $keyJson
        Write-CredoFileAtomic $m.DescPath (New-CredoDescriptorJson $Hub $m)
    } catch {
        Write-CredoHubLog $Hub ('mirror setup failed: ' + $_.Exception.Message)
        Remove-CredoMirrorFiles $Hub $m
        return $null
    }
    $Hub.Mirrors[$Key] = $m
    return $m
}

function Update-CredoMirror($Hub, $Mirror, $Fields) {
    $old = $Mirror.Fields
    $Mirror.Fields = $Fields
    if ([string]$old['name'] -ceq [string]$Fields['name'] -and [string]$old['status'] -ceq [string]$Fields['status']) { return }
    try { Write-CredoFileAtomic $Mirror.DescPath (New-CredoDescriptorJson $Hub $Mirror) } catch {
        Write-CredoHubLog $Hub ('descriptor update failed: ' + $_.Exception.Message)
    }
}

function Remove-CredoMirrorFiles($Hub, $Mirror) {
    foreach ($w in @($Mirror.Waiting)) { try { $w.Srv.Dispose() } catch {} }
    $Mirror.Waiting.Clear()
    foreach ($p in @($Mirror.DescPath, $Mirror.KeyPath)) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            $own = $true
            if ($p.EndsWith('.json')) {
                $o = Read-CredoJsonFile $p
                $own = ($null -ne $o -and (Get-CredoProp $o $Hub.Marker) -eq $true -and
                        [string](Get-CredoProp $o 'credoOwnerPid') -eq [string]$Hub.OwnerPid)
            }
            if ($own) { try { [System.IO.File]::Delete($p) } catch {} }
        }
    }
    [void](Stop-CredoHolder $Mirror.HolderPid $Mirror.HolderFt)
}

function Remove-CredoMirror($Hub, [string]$Key) {
    $m = $Hub.Mirrors[$Key]
    if ($null -eq $m) { return }
    $Hub.Mirrors.Remove($Key)
    foreach ($c in @($Hub.Conns)) { if ($c.Mirror -eq $m) { Close-CredoConn $Hub $c } }
    Remove-CredoMirrorFiles $Hub $m
}

function Remove-CredoAllMirrors($Hub) {
    foreach ($k in @($Hub.Mirrors.Keys)) { Remove-CredoMirror $Hub $k }
}

function Remove-CredoStaleMirrors($Hub) {
    # mirror files of THIS marker whose owner process is gone (a crashed earlier run):
    # descriptor, its key file and its holder. A live owner's files are left alone.
    if (-not (Test-Path -LiteralPath $Hub.SessDir)) { return }
    foreach ($f in [System.IO.Directory]::GetFiles($Hub.SessDir, '*.json')) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($f)
        if ($base -notmatch '^[0-9]+$') { continue }
        $o = Read-CredoJsonFile $f
        if ($null -eq $o -or (Get-CredoProp $o $Hub.Marker) -ne $true) { continue }
        $opid = [long](Get-CredoProp $o 'credoOwnerPid')
        $oft = [string](Get-CredoProp $o 'credoOwnerFt')
        if ($opid -ne $Hub.OwnerPid -and $opid -gt 0 -and (Get-CredoProcessFt $opid) -eq $oft) { continue }
        [void](Stop-CredoHolder ([long]$base) ([string](Get-CredoProp $o 'credoHolderFt')))
        $kn = [string](Get-CredoProp $o 'credoKeyFile')
        if ($kn -match ('^' + $base + '\.[0-9a-f]{64}\.key$')) {
            $kp = Join-Path $Hub.SessDir $kn
            try { if (Test-Path -LiteralPath $kp) { [System.IO.File]::Delete($kp) } } catch {}
        }
        try { [System.IO.File]::Delete($f) } catch {}
        Write-CredoHubLog $Hub ('removed stale mirror ' + $base)
    }
}

function Close-CredoConn($Hub, $Conn) {
    try { $Conn.Srv.Dispose() } catch {}
    $Hub.Conns.Remove($Conn)
}

function Start-CredoConnRead($Conn) {
    $Conn.Task = $Conn.Srv.ReadAsync($Conn.Buf, 0, $Conn.Buf.Length)
}

function Push-CredoConnLines($Hub, $Conn, [bool]$Final) {
    # hand on complete lines after a verified auth line; the auth line itself never
    # leaves this process. Final: also the trailing partial line (connection ended).
    $data = $Conn.Mem.ToArray()
    $pos = 0
    $out = New-Object System.IO.MemoryStream
    while ($true) {
        $nl = Get-CredoIndexOfNewline $data $pos
        if ($nl -lt 0) { break }
        $line = Split-CredoBytes $data $pos ($nl - $pos + 1)
        $pos = $nl + 1
        if (-not $Conn.Authed) {
            $tok = Get-CredoAuthToken $line
            if ($null -eq $tok -or -not (Test-CredoTokenEqual $tok $Conn.Mirror.Token)) {
                Write-CredoHubLog $Hub ('unauthenticated connection to mirror ' + $Conn.Mirror.Key + ' dropped')
                $Conn.Rejected = $true
                return
            }
            $Conn.Authed = $true
            continue
        }
        $out.Write($line, 0, $line.Length)
    }
    if ($Final -and $Conn.Authed -and $pos -lt $data.Length) {
        $out.Write($data, $pos, $data.Length - $pos)
        $pos = $data.Length
    }
    $Conn.Mem = New-Object System.IO.MemoryStream
    if ($pos -lt $data.Length) { $Conn.Mem.Write($data, $pos, $data.Length - $pos) }
    if ($out.Length -gt 0 -and $null -ne $Hub.OnMessage) { & $Hub.OnMessage $Conn.Mirror ($out.ToArray()) }
}

function Start-CredoSend($Hub, [long]$TargetPid, [string]$PipePath, [byte[]]$Data, $Id, [scriptblock]$Done) {
    # connect to a local Windows inbox, write the auth line from its key file plus Data,
    # close shortly after. Done is called as & $Done $Id $ok $err.
    $name = Get-CredoPipeName $PipePath
    if (-not (Test-CredoCcPipeName $name)) { & $Done $Id $false 'not a Claude Code pipe address'; return }
    $tok = Find-CredoToken $Hub.SessDir $TargetPid $PipePath
    if ($null -eq $tok) { & $Done $Id $false 'no key file for the target session'; return }
    $auth = New-CredoAuthLineBytes $tok
    $tok = $null
    $payload = New-Object byte[] ($auth.Length + $Data.Length)
    [Array]::Copy($auth, 0, $payload, 0, $auth.Length)
    [Array]::Copy($Data, 0, $payload, $auth.Length, $Data.Length)
    [Array]::Clear($auth, 0, $auth.Length)
    try {
        $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $name, [System.IO.Pipes.PipeDirection]::InOut,
            [System.IO.Pipes.PipeOptions]::Asynchronous)
        $task = $client.ConnectAsync(5000)
    } catch {
        [Array]::Clear($payload, 0, $payload.Length)
        & $Done $Id $false ('connect failed: ' + $_.Exception.Message)
        return
    }
    [void]$Hub.Sends.Add(@{ Client = $client; Task = $task; Stage = 'connect'; Payload = $payload; Id = $Id; Done = $Done;
                            Deadline = [DateTime]::UtcNow.AddSeconds(10); CloseAt = $null })
}

function Get-CredoHubTasks($Hub) {
    $t = New-Object System.Collections.ArrayList
    foreach ($m in $Hub.Mirrors.Values) { foreach ($w in $m.Waiting) { [void]$t.Add($w.Task) } }
    foreach ($c in $Hub.Conns) { if ($null -ne $c.Task) { [void]$t.Add($c.Task) } }
    foreach ($s in $Hub.Sends) { if ($null -ne $s.Task) { [void]$t.Add($s.Task) } }
    return ,$t
}

function Invoke-CredoHubPoll($Hub) {
    $now = [DateTime]::UtcNow
    # new connections on mirror pipes
    foreach ($m in @($Hub.Mirrors.Values)) {
        foreach ($w in @($m.Waiting)) {
            if (-not $w.Task.IsCompleted) { continue }
            $m.Waiting.Remove($w)
            if ($w.Task.IsFaulted -or $w.Task.IsCanceled) { try { $w.Srv.Dispose() } catch {}; continue }
            $c = @{ Mirror = $m; Srv = $w.Srv; Buf = (New-Object byte[] 65536); Mem = (New-Object System.IO.MemoryStream);
                    Authed = $false; Rejected = $false; Total = 0; Deadline = $now.AddMilliseconds($script:ConnTimeoutMs); Task = $null }
            [void]$Hub.Conns.Add($c)
            Start-CredoConnRead $c
        }
        while ($m.Waiting.Count -lt $script:ListenersPerMirror) {
            try { Add-CredoListener $Hub $m } catch { Write-CredoHubLog $Hub ('listener failed: ' + $_.Exception.Message); break }
        }
    }
    # reads on accepted connections
    foreach ($c in @($Hub.Conns)) {
        if ($c.Task.IsCompleted) {
            $n = 0
            if (-not ($c.Task.IsFaulted -or $c.Task.IsCanceled)) { $n = $c.Task.Result }
            if ($n -gt 0) {
                $c.Total += $n
                if ($c.Total -gt $script:MaxMessage) { Close-CredoConn $Hub $c; continue }
                $c.Mem.Write($c.Buf, 0, $n)
                Push-CredoConnLines $Hub $c $false
                if ($c.Rejected) { Close-CredoConn $Hub $c; continue }
                Start-CredoConnRead $c
                continue
            }
            Push-CredoConnLines $Hub $c $true
            Close-CredoConn $Hub $c
            continue
        }
        if ($now -gt $c.Deadline) {
            Push-CredoConnLines $Hub $c $true
            Close-CredoConn $Hub $c
        }
    }
    # outgoing sends
    foreach ($s in @($Hub.Sends)) {
        if ($s.Stage -eq 'linger') {
            if ($now -ge $s.CloseAt) { try { $s.Client.Dispose() } catch {}; $Hub.Sends.Remove($s) }
            continue
        }
        if ($s.Task.IsCompleted) {
            if ($s.Task.IsFaulted -or $s.Task.IsCanceled) {
                $err = if ($s.Task.Exception) { $s.Task.Exception.InnerException.Message } else { 'canceled' }
                [Array]::Clear($s.Payload, 0, $s.Payload.Length)
                try { $s.Client.Dispose() } catch {}
                $Hub.Sends.Remove($s)
                & $s.Done $s.Id $false ($s.Stage + ' failed: ' + $err)
                continue
            }
            if ($s.Stage -eq 'connect') {
                $s.Stage = 'write'
                $s.Task = $s.Client.WriteAsync($s.Payload, 0, $s.Payload.Length)
                continue
            }
            [Array]::Clear($s.Payload, 0, $s.Payload.Length)
            $s.Stage = 'linger'
            $s.Task = $null
            # close shortly after the write, like a Claude Code sender: the inbox reads
            # what is in the pipe, closing at once has lost nothing in tests either
            $s.CloseAt = $now.AddMilliseconds(300)
            & $s.Done $s.Id $true ''
            continue
        }
        if ($now -gt $s.Deadline) {
            [Array]::Clear($s.Payload, 0, $s.Payload.Length)
            try { $s.Client.Dispose() } catch {}
            $Hub.Sends.Remove($s)
            & $s.Done $s.Id $false ($s.Stage + ' timed out')
        }
    }
}

function Test-CredoHolders($Hub) {
    # mirrors whose holder died (killed by someone): drop them; the next publish or
    # roster recreates them with a new holder
    $dead = @()
    foreach ($m in $Hub.Mirrors.Values) { if ((Get-CredoProcessFt $m.HolderPid) -ne $m.HolderFt) { $dead += $m.Key } }
    foreach ($k in $dead) { Write-CredoHubLog $Hub ('holder of mirror ' + $k + ' died'); Remove-CredoMirror $Hub $k }
    $Hub.PidDomain = Get-CredoPidDomain $Hub.SessDir
}

function Wait-CredoTasks($Tasks, [int]$TimeoutMs) {
    if ($Tasks.Count -eq 0) { Start-Sleep -Milliseconds $TimeoutMs; return }
    $arr = New-Object 'System.Threading.Tasks.Task[]' $Tasks.Count
    for ($i = 0; $i -lt $Tasks.Count; $i++) { $arr[$i] = $Tasks[$i] }
    [void][System.Threading.Tasks.Task]::WaitAny($arr, $TimeoutMs)
}

# --- watchdog: cleanup after a hard kill ------------------------------------------------

function Start-CredoWatchdog($Hub) {
    # a separate hidden powershell.exe that waits for this process to end and then
    # removes the mirrors it left (only files with this marker whose owner is gone, only
    # holders proven by pid + creation time + image name). A clean exit has removed them
    # already; the watchdog then finds nothing and ends.
    $q = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
    $cmd = '. ' + (& $q (Join-Path $PSScriptRoot 'credo-win-common.ps1')) + '; Invoke-CredoWatchdog ' + $Hub.OwnerPid + ' ' +
           (& $q $Hub.OwnerFt) + ' ' + (& $q $Hub.SessDir) + ' ' + (& $q $Hub.Marker)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
                     [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try { $p = [System.Diagnostics.Process]::Start($psi); $p.Dispose() } catch {
        Write-CredoHubLog $Hub ('watchdog not started: ' + $_.Exception.Message)
    }
}

function Invoke-CredoWatchdog([long]$OwnerPid, [string]$OwnerFt, [string]$SessDir, [string]$Marker) {
    try {
        $p = [System.Diagnostics.Process]::GetProcessById([int]$OwnerPid)
        if ([string]$p.StartTime.ToFileTimeUtc() -eq $OwnerFt) { $p.WaitForExit() }
        $p.Dispose()
    } catch {
        while ((Get-CredoProcessFt $OwnerPid) -eq $OwnerFt) { Start-Sleep -Seconds 2 }
    }
    $me = [System.Diagnostics.Process]::GetCurrentProcess()
    Remove-CredoStaleMirrors @{ SessDir = $SessDir; Marker = $Marker; OwnerPid = [long]$me.Id; OwnerFt = ''; OnLog = $null }
}

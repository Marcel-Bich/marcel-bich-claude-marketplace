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
    try {
        # [NullString]::Value, not $null: PowerShell turns $null into '' for a string
        # parameter, and File.Replace rejects '' as a backup path ("the path is not of a
        # legal form") - every descriptor UPDATE failed that way (item #196)
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
        else { [System.IO.File]::Move($tmp, $Path) }
    } catch {
        try { [System.IO.File]::Delete($tmp) } catch {}
        throw
    }
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

function Test-CredoElevated {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object System.Security.Principal.WindowsPrincipal $id).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-CredoPipeOwnerSid([string]$Name) {
    # owner SID of a pipe's security descriptor ($null when unreadable). Opens one
    # read-only client connection that sends nothing (a Claude Code inbox closes it at
    # its first-line deadline), so it is only used after an access-denied failure.
    try {
        $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Name,
            [System.IO.Pipes.PipeAccessRights]'Read, ReadPermissions', [System.IO.Pipes.PipeOptions]::None,
            [System.Security.Principal.TokenImpersonationLevel]::None, [System.IO.HandleInheritability]::None)
        try {
            $c.Connect(500)
            return $c.GetAccessControl().GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        } finally { $c.Dispose() }
    } catch { return $null }
}

function Get-CredoInboxOwner($Hub, [string]$Name) {
    # owner SID of an inbox pipe, cached per pipe; an unreadable owner is not cached
    if (-not $Hub.ContainsKey('OwnerCache')) { $Hub.OwnerCache = @{} }
    if (-not $Hub.OwnerCache.ContainsKey($Name)) { $Hub.OwnerCache[$Name] = Get-CredoPipeOwnerSid $Name }
    $owner = $Hub.OwnerCache[$Name]
    if ($null -eq $owner) { $Hub.OwnerCache.Remove($Name) }
    return $owner
}

function Test-CredoUseElevHelper([bool]$Denied, [string]$Owner, [bool]$SelfElevated) {
    # the elevated sender helper is used only for what it exists for: write access denied
    # to an inbox owned by Administrators (an elevated session) while this process is not
    # elevated. Every other failure keeps its own honest reason.
    return ($Denied -and $Owner -eq 'S-1-5-32-544' -and -not $SelfElevated)
}

function Get-CredoAccessDeniedText($Hub, [string]$Name) {
    # why Windows refused write access to a session inbox. A Claude Code session that
    # runs elevated creates its pipe with the default DACL of an elevated token: owner
    # BUILTIN\Administrators, full access for Administrators and SYSTEM, only READ for
    # Everyone. A non-elevated client (the bridge started through WSL interop) has the
    # Administrators group as deny-only and gets "access denied" for write.
    $owner = Get-CredoInboxOwner $Hub $Name
    if ($owner -eq 'S-1-5-32-544' -and -not (Test-CredoElevated)) {
        return ('access denied: the target Windows session runs elevated (as administrator) and this bridge does ' +
                'not; Windows only lets elevated processes write into an elevated session''s inbox pipe')
    }
    return ('access denied to the session inbox pipe (pipe owner ' + $(if ($owner) { $owner } else { 'unknown' }) + ')')
}

# --- elevated sender helper (credo-win-elevsend.ps1, item #196) ------------------------
$script:ElevTask = 'credo-win-elevsend'
$script:ElevInstallHint = 'WSL -> elevated Windows sessions need the elevated sender helper; install it now (one UAC prompt): `credo-win-bridge.py elevsend-install`'

function Get-CredoUserSid {
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-CredoElevSendPipeName {
    return ('LOCAL\credo-elevsend-' + (Get-CredoUserSid))
}

function Test-CredoElevSendInstalled {
    if ($env:CREDO_WIN_ELEVSEND_INSTALLED) { return ($env:CREDO_WIN_ELEVSEND_INSTALLED -eq '1') }
    return (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'credo\credo-win-elevsend.ps1'))
}

function Start-CredoElevSendTask($Hub) {
    # start the helper's scheduled task (no UAC: the elevation is in the task), at most
    # every 30 s
    $now = [DateTime]::UtcNow
    if ($Hub.ContainsKey('ElevStartAt') -and $now -lt $Hub.ElevStartAt) { return $false }
    $Hub.ElevStartAt = $now.AddSeconds(30)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\schtasks.exe'
        $psi.Arguments = '/Run /TN ' + $script:ElevTask
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.Dispose()
        Write-CredoHubLog $Hub 'elevated sender helper: started its task (on demand)'
        return $true
    } catch {
        Write-CredoHubLog $Hub ('could not start the elevated sender helper: ' + $_.Exception.Message)
        return $false
    }
}

function Get-CredoBridgeAliveFile {
    if ($env:CREDO_WIN_BRIDGE_ALIVE_FILE) { return $env:CREDO_WIN_BRIDGE_ALIVE_FILE }
    return (Join-Path $env:LOCALAPPDATA 'credo\win-bridge-alive.json')
}

function Set-CredoBridgeAlive($Hub) {
    # tells the elevated sender helper that a credo bridge runs (pid + creation time);
    # without it the helper exits at once and never opens its pipe
    try {
        $p = Get-CredoBridgeAliveFile
        $d = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d) }
        Write-CredoFileAtomic $p ('{"pid":' + $Hub.OwnerPid + ',"ft":"' + $Hub.OwnerFt + '"}')
    } catch { Write-CredoHubLog $Hub ('alive file not written: ' + $_.Exception.Message) }
}

function Clear-CredoBridgeAlive($Hub) {
    # remove the alive file, but only while it is still this process's
    try {
        $p = Get-CredoBridgeAliveFile
        $o = Read-CredoJsonFile $p
        if ($null -ne $o -and [string](Get-CredoProp $o 'pid') -eq [string]$Hub.OwnerPid) { [System.IO.File]::Delete($p) }
    } catch {}
}

function New-CredoElevSendRequest([string]$Name, [byte[]]$Payload) {
    # one request line for the helper: {"v":1,"pipe":<inbox pipe name>,"data":<base64>}
    $line = '{"v":1,"pipe":' + (ConvertTo-Json -InputObject $Name -Compress) + ',"data":"' +
            [Convert]::ToBase64String($Payload) + '"}' + "`n"
    return $script:Utf8.GetBytes($line)
}

function Read-CredoElevSendReply([byte[]]$Line) {
    # @{ Ok; Err } of a helper reply line
    try { $o = $script:Utf8.GetString($Line).Trim() | ConvertFrom-Json } catch { return @{ Ok = $false; Err = 'unreadable helper reply' } }
    if ($null -eq $o -or $o -isnot [System.Management.Automation.PSCustomObject]) { return @{ Ok = $false; Err = 'unreadable helper reply' } }
    $ok = $o.PSObject.Properties['ok']
    if ($null -ne $ok -and $ok.Value -eq $true) { return @{ Ok = $true; Err = '' } }
    $e = $o.PSObject.Properties['err']
    return @{ Ok = $false; Err = $(if ($null -ne $e) { [string]$e.Value } else { 'helper refused' }) }
}

function Start-CredoElevSendPath($Hub, $Send) {
    # hand the prepared bytes (auth line + message) to the elevated helper
    if (-not (Test-CredoElevSendInstalled)) {
        Stop-CredoSend $Hub $Send $false ((Get-CredoAccessDeniedText $Hub $Send.Name) + '; ' + $script:ElevInstallHint)
        return
    }
    # the helper exits after 5 idle minutes: unless it answered within the last 4, start
    # its task (a running one ignores the start). No probe a non-elevated process could
    # fake (such as a pre-created mutex) keeps the bridge from starting it.
    $now = [DateTime]::UtcNow
    if (-not $Hub.ContainsKey('ElevLastOk') -or $now -gt $Hub.ElevLastOk.AddMinutes(4)) {
        if (Start-CredoElevSendTask $Hub) { $Send.ElevStarted = $true }
    }
    $Send.Via = 'helper'
    $Send.Attempts++
    $left = [int][Math]::Max(100, ($Send.Deadline - [DateTime]::UtcNow).TotalMilliseconds)
    # explicit rights: read/write data plus read permissions (for the owner check);
    # never FILE_CREATE_PIPE_INSTANCE, which the helper pipe grants nobody but admins
    $Send.Client = New-Object System.IO.Pipes.NamedPipeClientStream('.', (Get-CredoElevSendPipeName),
        [System.IO.Pipes.PipeAccessRights]'ReadData, WriteData, ReadAttributes, ReadPermissions',
        [System.IO.Pipes.PipeOptions]::Asynchronous, [System.Security.Principal.TokenImpersonationLevel]::Identification,
        [System.IO.HandleInheritability]::None)
    $Send.Stage = 'hconnect'
    $Send.Task = $Send.Client.ConnectAsync($left)
}

function Test-CredoElevSendOwner($Client) {
    # only a helper pipe owned by Administrators is trusted: a non-elevated process that
    # squats the name cannot set that owner, so it never receives the message
    try { return ($Client.GetAccessControl().GetOwner([System.Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544') }
    catch { return $false }
}

function Start-CredoSendConnect($Send) {
    $left = [int][Math]::Max(100, ($Send.Deadline - [DateTime]::UtcNow).TotalMilliseconds)
    $Send.Attempts++
    $Send.Client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Send.Name, [System.IO.Pipes.PipeDirection]::InOut,
        [System.IO.Pipes.PipeOptions]::Asynchronous)
    $Send.Stage = 'connect'
    $Send.Task = $Send.Client.ConnectAsync($left)
}

function Stop-CredoSend($Hub, $Send, [bool]$Ok, [string]$Err) {
    [Array]::Clear($Send.Payload, 0, $Send.Payload.Length)
    if ($Ok) {
        $Send.Stage = 'linger'
        $Send.Task = $null
        # close shortly after the write, like a Claude Code sender: the inbox reads what
        # is in the pipe, closing at once has lost nothing in tests either
        $Send.CloseAt = [DateTime]::UtcNow.AddMilliseconds(300)
    } else {
        if ($null -ne $Send.Client) { try { $Send.Client.Dispose() } catch {} }
        $Hub.Sends.Remove($Send)
    }
    & $Send.Done $Send.Id $Ok $Err
}

function Start-CredoSend($Hub, [long]$TargetPid, [string]$PipePath, [byte[]]$Data, $Id, [scriptblock]$Done, [int]$TtlMs = 10000) {
    # connect to a local Windows inbox, write the auth line from its key file plus Data,
    # close shortly after. Done is called exactly once as & $Done $Id $ok $err; ok means
    # the bytes were written into the inbox pipe. A transient connect failure is retried
    # until TtlMs is used up; access denied is final and reported with its cause.
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
    $s = @{ Name = $name; Client = $null; Task = $null; Stage = 'connect'; Payload = $payload; Id = $Id; Done = $Done;
            Deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(200, $TtlMs)); CloseAt = $null; RetryAt = $null;
            Attempts = 0; LastErr = ''; Via = 'direct'; ElevStarted = $false; Request = $null; Reply = $null; Buf = $null }
    [void]$Hub.Sends.Add($s)
    try { Start-CredoSendConnect $s } catch { Step-CredoSendFailure $Hub $s $_.Exception }
}

function Step-CredoSendFailure($Hub, $Send, $Ex) {
    # a failed connect: final for access denied (or a used-up deadline), else retry soon
    while ($null -ne $Ex.InnerException -and ($Ex -is [System.AggregateException] -or
           $Ex -is [System.Management.Automation.MethodInvocationException])) { $Ex = $Ex.InnerException }
    if ($null -ne $Send.Client) { try { $Send.Client.Dispose() } catch {}; $Send.Client = $null }
    $Send.Task = $null
    if ($Ex -is [System.UnauthorizedAccessException]) {
        if (Test-CredoUseElevHelper $true (Get-CredoInboxOwner $Hub $Send.Name) (Test-CredoElevated)) {
            try { Start-CredoElevSendPath $Hub $Send } catch {
                Stop-CredoSend $Hub $Send $false ('elevated sender helper not usable: ' + $_.Exception.Message)
            }
            return
        }
        Stop-CredoSend $Hub $Send $false (Get-CredoAccessDeniedText $Hub $Send.Name)
        return
    }
    $Send.LastErr = $Ex.Message
    $retryAt = [DateTime]::UtcNow.AddMilliseconds(250)
    if ($retryAt.AddMilliseconds(100) -ge $Send.Deadline) {
        Stop-CredoSend $Hub $Send $false ('connect failed after ' + $Send.Attempts + ' attempt(s): ' + $Ex.Message)
        return
    }
    $Send.Stage = 'retry'
    $Send.RetryAt = $retryAt
}

function Step-CredoElevSend($Hub, $Send) {
    # one completed stage of a send through the elevated helper
    $t = $Send.Task
    if ($t.IsFaulted -or $t.IsCanceled) {
        # the helper is gone or broken: forget its last answer, so the next send starts
        # its task again instead of trusting it for up to 4 more minutes
        [void]$Hub.Remove('ElevLastOk')
        $err = if ($t.Exception) { $t.Exception.InnerException.Message } else { 'canceled' }
        if ($Send.Stage -eq 'hconnect') {
            $err = 'elevated sender helper not reachable: ' + $err
            if ($Send.ElevStarted) { $err += ' (its task was just started; send again in a few seconds)' }
        } else { $err = 'elevated sender helper ' + $Send.Stage + ' failed: ' + $err }
        Stop-CredoSend $Hub $Send $false $err
        return
    }
    switch ($Send.Stage) {
        'hconnect' {
            if (-not (Test-CredoElevSendOwner $Send.Client)) {
                Stop-CredoSend $Hub $Send $false 'the elevated sender helper pipe is not owned by Administrators - refused, nothing sent'
                return
            }
            $req = New-CredoElevSendRequest $Send.Name $Send.Payload
            $Send.Request = $req
            $Send.Stage = 'hwrite'
            $Send.Task = $Send.Client.WriteAsync($req, 0, $req.Length)
        }
        'hwrite' {
            [Array]::Clear($Send.Request, 0, $Send.Request.Length)
            $Send.Reply = New-Object System.IO.MemoryStream
            $Send.Buf = New-Object byte[] 4096
            $Send.Stage = 'hread'
            $Send.Task = $Send.Client.ReadAsync($Send.Buf, 0, $Send.Buf.Length)
        }
        'hread' {
            $n = $t.Result
            if ($n -gt 0) { $Send.Reply.Write($Send.Buf, 0, $n) }
            $data = $Send.Reply.ToArray()
            $nl = Get-CredoIndexOfNewline $data 0
            if ($nl -lt 0 -and $n -gt 0 -and $data.Length -lt 65536) {
                $Send.Task = $Send.Client.ReadAsync($Send.Buf, 0, $Send.Buf.Length)
                return
            }
            $line = if ($nl -ge 0) { Split-CredoBytes $data 0 $nl } else { $data }
            $r = Read-CredoElevSendReply $line
            $Hub.ElevLastOk = [DateTime]::UtcNow
            $err = if ($r.Ok) { '' } else { 'elevated sender helper: ' + $r.Err }
            Stop-CredoSend $Hub $Send $r.Ok $err
        }
    }
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
        if ($s.Stage -eq 'retry') {
            if ($now -ge $s.RetryAt) { try { Start-CredoSendConnect $s } catch { Step-CredoSendFailure $Hub $s $_.Exception } }
            continue
        }
        if ($s.Via -eq 'helper' -and $null -ne $s.Task -and $s.Task.IsCompleted) {
            Step-CredoElevSend $Hub $s
            continue
        }
        if ($s.Task.IsCompleted) {
            if ($s.Task.IsFaulted -or $s.Task.IsCanceled) {
                if ($s.Stage -eq 'connect') {
                    $ex = if ($s.Task.Exception) { $s.Task.Exception } else { New-Object System.OperationCanceledException }
                    Step-CredoSendFailure $Hub $s $ex
                    continue
                }
                # a failed write is never retried: part of it may be in the inbox already
                $err = if ($s.Task.Exception) { $s.Task.Exception.InnerException.Message } else { 'canceled' }
                Stop-CredoSend $Hub $s $false ($s.Stage + ' failed: ' + $err)
                continue
            }
            if ($s.Stage -eq 'connect') {
                $s.Stage = 'write'
                $s.Task = $s.Client.WriteAsync($s.Payload, 0, $s.Payload.Length)
                continue
            }
            Stop-CredoSend $Hub $s $true ''
            continue
        }
        # hard end at the deadline, also for a pending write: the caller (the WSL
        # holder) stops waiting for the verdict soon after it
        if ($now -gt $s.Deadline) {
            if ($s.Via -eq 'helper') { [void]$Hub.Remove('ElevLastOk') }
            $why = if ($s.LastErr) { ' (last error: ' + $s.LastErr + ')' } else { '' }
            Stop-CredoSend $Hub $s $false ($s.Stage + ' timed out' + $why)
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

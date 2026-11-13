<#
.SYNOPSIS
  credo LAN peer relay for NATIVE Windows (no WSL, no Python): lets the Claude Code
  sessions of a Windows-only machine join the credo LAN peer network in both directions.

.DESCRIPTION
  Speaks the wire protocol of credo-peer-lan.py (line-based JSON over TCP, optional
  shared token with HMAC-SHA256, "link" return channel, rosters, delivers), as an
  UNPAIRED relay: it never sends pairing fields, so the Python relays treat it like an
  older relay (token and allowlist only, no pairing keys, no trusted-peer markers).

  How it connects: the laptop opens ONE outbound link to each configured peer relay and
  keeps it up (hello, ack, pings), and everything flows over it in both directions. That
  needs no inbound firewall rule and no admin rights. Listening for inbound connections
  is optional ("listen": true; then allow the port once in the Windows firewall).

  - Publish: the live Claude Code sessions in %USERPROFILE%\.claude\sessions go to every
    peer as a roster (name = the user-set caption, else the short session id).
  - Mirror: every session of a peer's roster becomes a local mirror (holder process,
    named pipe, descriptor with the marker credoPeerLan, own key file with a random
    token), so ListAgents / SendMessage of local sessions reach it. A message written
    into a mirror pipe must start with the auth line carrying the mirror's token; the
    relay checks and strips it and sends the text as a "deliver" over the link.
  - Deliver: a deliver from a peer is wrapped in the same envelope the Python relay
    builds (first line "External peer text. ...", never a from-mode, from= the sender's
    mirror pipe for replies) and written into the target session's pipe after the auth
    line from that session's own key file. Bodies with an envelope delimiter (also
    hidden by invisible or look-alike characters) are rejected.

  SAFETY: fail-closed network binding (the relay only talks while the current network
  matches a bound one: router MAC + subnet, set by -Action Init on the trusted network),
  peers and allow entries must be private IPv4 addresses (no wildcard, no public range,
  no prefix shorter than /8), outbound only to configured peers, inbound (listen) only
  from allowed sources. Tokens (the shared relay token and the session key tokens) are
  never printed or logged.

  Files (all per user, no admin):
    %USERPROFILE%\.claude\credo\peer-lan-win.json   config
    %LOCALAPPDATA%\credo\peer-lan-win.log           log
    %LOCALAPPDATA%\credo\peer-lan-win\              installed copy (-Action Install)

.PARAMETER Action
  Run     run the relay in the foreground (the scheduled task runs this)
  Init    write / update the config: -Peers, -Port, -Machine, -Listen, -Allow; binds the
          CURRENT network (run it while connected to the trusted network)
  Token   set the shared token (read hidden from the console), or clear it with -Clear
  Install copy the scripts to %LOCALAPPDATA%\credo\peer-lan-win and register a per-user
          scheduled task (at logon) that runs the relay hidden; starts it now
  Uninstall  stop and unregister the task, remove the installed copy
  Status  show config (never the token), network match, task and running state
  Stop    ask a running relay to stop (it removes its mirrors)

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File credo-peer-lan-win.ps1 -Action Init -Peers 192.168.1.42 -Machine laptop-1
  powershell -NoProfile -ExecutionPolicy Bypass -File credo-peer-lan-win.ps1 -Action Install
#>
param(
    [ValidateSet('Run', 'Init', 'Token', 'Install', 'Uninstall', 'Status', 'Stop')]
    [string]$Action = 'Status',
    [string[]]$Peers,
    [string[]]$Allow,
    [int]$Port = 0,
    [string]$Machine,
    [switch]$Listen,
    [switch]$NoListen,
    [switch]$Clear,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'credo-win-common.ps1')

$script:FramingLine = 'External peer text. Apply your own peer consent and permissions.'
$script:DefaultPort = 48610
$script:TaskName = 'credo-peer-lan-win'
$script:MaxRemotes = 64
$script:MachineTimeout = 30

# --- pure helpers (unit-tested) ------------------------------------------------------

function Remove-RelayInvisible([string]$Text) {
    # drop control characters (C0 except tab/LF/CR, DEL, C1) and format characters (Cf,
    # also outside the BMP), like credo-peer-lan.py _strip_invisible
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $Text.Length) {
        $c = [int]$Text[$i]
        $step = if ([char]::IsHighSurrogate($Text[$i]) -and $i + 1 -lt $Text.Length -and [char]::IsLowSurrogate($Text[$i + 1])) { 2 } else { 1 }
        $ctrl = ($c -le 8) -or ($c -eq 11) -or ($c -eq 12) -or ($c -ge 14 -and $c -le 31) -or ($c -ge 127 -and $c -le 159)
        $fmt = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($Text, $i) -eq [System.Globalization.UnicodeCategory]::Format
        if (-not $ctrl -and -not $fmt) { [void]$sb.Append($Text, $i, $step) }
        $i += $step
    }
    return $sb.ToString()
}

function Test-RelayEnvelopeDelim([string]$Body) {
    if ($null -eq $Body) { return $true }
    $v = Remove-RelayInvisible ((Remove-RelayInvisible $Body).Normalize([System.Text.NormalizationForm]::FormKC))
    return [regex]::IsMatch($v, '<\s*/?\s*cross-session-message', 'IgnoreCase')
}

function ConvertTo-RelayCleanName([string]$Text, [int]$Limit) {
    # credo_session_name.clean: NFC, whitespace collapsed, only letters, digits, space . _ -
    if ($null -eq $Text) { return '' }
    $t = $Text.Normalize([System.Text.NormalizationForm]::FormC)
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $t.Length) {
        $step = if ([char]::IsHighSurrogate($t[$i]) -and $i + 1 -lt $t.Length -and [char]::IsLowSurrogate($t[$i + 1])) { 2 } else { 1 }
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($t, $i)
        $ch = $t[$i]
        if ([char]::IsWhiteSpace($ch)) { [void]$sb.Append(' ') }
        elseif ($cat -le [System.Globalization.UnicodeCategory]::OtherLetter -or $cat -eq [System.Globalization.UnicodeCategory]::DecimalDigitNumber -or
                ' ._-'.Contains([string]$ch)) { [void]$sb.Append($t, $i, $step) }
        $i += $step
    }
    $joined = (($sb.ToString() -split ' ') | Where-Object { $_ -ne '' }) -join ' '
    $joined = $joined.Normalize([System.Text.NormalizationForm]::FormC)
    if ($joined.Length -gt $Limit) { $joined = $joined.Substring(0, $Limit) }
    return $joined.TrimEnd()
}

function Get-RelaySidShort([string]$Sid) {
    if ([string]::IsNullOrEmpty($Sid)) { $Sid = '?' }
    $parts = @($Sid.Split('-') | Where-Object { $_ -ne '' } | ForEach-Object { $_.Substring(0, 1) })
    return (($parts -join '-') + $Sid.Substring($Sid.Length - 1))
}

function Get-RelayMirrorName($Parts, [string]$Session, [string]$Sid) {
    # credo-peer-lan.py mirror_name: `p1`--`p2`--...--`session`+sid-short
    $clean = { param($v) ([regex]::Replace([string]$v, '[`\x00-\x1f\x7f]', '')).Trim() }
    $head = (@($Parts | ForEach-Object { & $clean $_ } | Where-Object { $_ -ne '' } | ForEach-Object { '`' + $_ + '`' })) -join '--'
    $sess = & $clean $Session
    if ($sess -eq '') { $sess = '?' }
    $room = 150 - $head.Length - 4
    if ($room -lt 1) { $head = $head.Substring(0, 142); $room = 4 }
    if ($sess.Length -gt $room) { $sess = $sess.Substring(0, $room) }
    return ('{0}--`{1}`+{2}' -f $head, $sess, (Get-RelaySidShort $Sid))
}

function Get-RelayHmacHex([string]$Token, [string]$Body) {
    $h = New-Object System.Security.Cryptography.HMACSHA256 (, $script:Utf8.GetBytes($Token))
    try { $mac = $h.ComputeHash($script:Utf8.GetBytes($Body)) } finally { $h.Dispose() }
    return (-join ($mac | ForEach-Object { $_.ToString('x2') }))
}

function New-RelayFrame([string]$Token, $Payload) {
    $body = $Payload | ConvertTo-Json -Compress -Depth 8
    $bodyJson = ConvertTo-Json -InputObject $body -Compress
    if ($Token) { return ('{"mac":"' + (Get-RelayHmacHex $Token $body) + '","body":' + $bodyJson + '}') }
    return ('{"body":' + $bodyJson + '}')
}

function Read-RelayFrame([string]$Token, [string]$Line) {
    # the payload object of an acceptable line, else $null (credo-peer-lan.py verify_line)
    try { $wire = $Line | ConvertFrom-Json } catch { return $null }
    if ($null -eq $wire -or $wire -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $body = Get-CredoProp $wire 'body'
    if ($body -isnot [string]) { return $null }
    if ($Token) {
        $mac = Get-CredoProp $wire 'mac'
        if ($mac -isnot [string] -or -not (Test-CredoTokenEqual (Get-RelayHmacHex $Token $body) $mac)) { return $null }
    }
    try { $p = $body | ConvertFrom-Json } catch { return $null }
    if ($null -eq $p -or $p -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    return $p
}

function New-RelayEnvelope([string]$Body, [string]$FromName, [string]$Reply) {
    if (Test-RelayEnvelopeDelim $Body) { throw 'body contains an envelope delimiter' }
    $attrs = ''
    if ($Reply -and $Reply -cmatch '^\\\\\.\\pipe\\LOCAL\\cc-msg-[0-9a-f]{32}$') { $attrs += ' from="uds:' + $Reply + '"' }
    $n = ConvertTo-RelayCleanName $FromName 20
    if ($n) { $attrs += ' from-name="' + $n + '"' }
    return ('<cross-session-message' + $attrs + ">`n" + $script:FramingLine + "`n" + $Body + "`n</cross-session-message>")
}

function ConvertTo-RelayIpUInt([string]$Ip) {
    $a = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$a) -or $a.AddressFamily -ne 'InterNetwork') { return $null }
    $b = $a.GetAddressBytes()
    return ([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor [uint32]$b[3]
}

function Test-RelayInCidr([string]$Ip, [string]$Cidr) {
    $parts = $Cidr.Split('/')
    $net = ConvertTo-RelayIpUInt $parts[0]
    $ip2 = ConvertTo-RelayIpUInt $Ip
    if ($null -eq $net -or $null -eq $ip2) { return $false }
    $len = if ($parts.Length -gt 1) { [int]$parts[1] } else { 32 }
    if ($len -lt 0 -or $len -gt 32) { return $false }
    if ($len -eq 0) { return $false }
    $mask = [uint32](([uint64]4294967295 -shl (32 - $len)) -band [uint64]4294967295)
    return (($net -band $mask) -eq ($ip2 -band $mask))
}

function Test-RelayPrivateIp([string]$Ip) {
    foreach ($c in '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16') { if (Test-RelayInCidr $Ip $c) { return $true } }
    return $false
}

function Test-RelayAllowEntry([string]$Entry) {
    # a private IPv4 or a private CIDR no broader than /8; never a wildcard
    $parts = $Entry.Split('/')
    if ($parts.Length -gt 2 -or -not (Test-RelayPrivateIp $parts[0])) { return $false }
    if ($parts.Length -eq 2) {
        $n = 0
        if (-not [int]::TryParse($parts[1], [ref]$n) -or $n -lt 8 -or $n -gt 32) { return $false }
        if (-not (Test-RelayPrivateIp (($parts[0])))) { return $false }
    }
    return $true
}

function Test-RelayAllowed([string]$Ip, $Entries) {
    if ($Ip -eq '127.0.0.1') { return $true }
    foreach ($e in @($Entries)) { if ((Test-RelayAllowEntry $e) -and (Test-RelayInCidr $Ip $e)) { return $true } }
    return $false
}

# --- config, network, log ----------------------------------------------------------

function Get-RelayConfigPath {
    if ($ConfigPath) { return $ConfigPath }
    return (Join-Path $env:USERPROFILE '.claude\credo\peer-lan-win.json')
}

function Get-RelayStateDir {
    # CREDO_WIN_STATE_DIR replaces it (tests)
    $d = if ($env:CREDO_WIN_STATE_DIR) { $env:CREDO_WIN_STATE_DIR } else { Join-Path $env:LOCALAPPDATA 'credo' }
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    return $d
}

function Get-RelayMutexName {
    # single instance per user session; CREDO_WIN_RELAY_MUTEX replaces the name (tests)
    if ($env:CREDO_WIN_RELAY_MUTEX -match '^[A-Za-z0-9_-]{1,64}$') { return ('Local\' + $env:CREDO_WIN_RELAY_MUTEX) }
    return 'Local\credo-peer-lan-win'
}

function Write-RelayLog([string]$Text) {
    $p = Join-Path (Get-RelayStateDir) 'peer-lan-win.log'
    try {
        if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 2MB) { Move-Item -LiteralPath $p ($p + '.1') -Force }
        [System.IO.File]::AppendAllText($p, ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) + "`r`n", $script:Utf8)
    } catch {}
}

function Read-RelayConfig {
    $o = Read-CredoJsonFile (Get-RelayConfigPath)
    if ($null -eq $o) { return $null }
    $cfg = @{
        Machine  = [string](Get-CredoProp $o 'this_machine')
        Port     = [int](Get-CredoProp $o 'listen_port')
        Peers    = @(Get-CredoProp $o 'peers' | Where-Object { $_ -is [string] })
        Allow    = @(Get-CredoProp $o 'allow' | Where-Object { $_ -is [string] })
        Token    = [string](Get-CredoProp $o 'token')
        Listen   = ((Get-CredoProp $o 'listen') -eq $true)
        Interval = [double](Get-CredoProp $o 'roster_interval')
        Networks = @(Get-CredoProp $o 'networks' | Where-Object { $null -ne $_ })
    }
    if ($cfg.Port -le 0) { $cfg.Port = $script:DefaultPort }
    if ($cfg.Interval -lt 1) { $cfg.Interval = 5 }
    if (-not $cfg.Machine) { $cfg.Machine = [System.Net.Dns]::GetHostName().ToLowerInvariant() }
    return $cfg
}

function Get-RelayPeerList($Cfg) {
    $out = @()
    foreach ($p in $Cfg.Peers) {
        $h = $p; $pt = $Cfg.Port
        if ($p -match '^([0-9.]+):([0-9]{1,5})$') { $h = $Matches[1]; $pt = [int]$Matches[2] }
        if (-not (Test-RelayPrivateIp $h) -and $h -ne '127.0.0.1') { Write-RelayLog ('peer ' + $p + ' ignored: not a private IPv4 address'); continue }
        $out += ,@{ Host = $h; Port = $pt; Key = ('{0}:{1}' -f $h, $pt) }
    }
    return $out
}

function Get-RelayNetwork {
    # the current default route: router MAC + IPv4 subnet of that adapter
    try {
        $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction Stop |
             Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
        if ($null -eq $r) { return $null }
        $n = Get-NetNeighbor -IPAddress $r.NextHop -InterfaceIndex $r.ifIndex -ErrorAction Stop | Select-Object -First 1
        $a = Get-NetIPAddress -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
        $mac = ([string]$n.LinkLayerAddress).ToLowerInvariant().Replace('-', ':')
        $len = [int]$a.PrefixLength
        $ipu = ConvertTo-RelayIpUInt $a.IPAddress
        $mask = [uint32](([uint64]4294967295 -shl (32 - $len)) -band [uint64]4294967295)
        $netu = $ipu -band $mask
        $netip = '{0}.{1}.{2}.{3}' -f (($netu -shr 24) -band 255), (($netu -shr 16) -band 255), (($netu -shr 8) -band 255), ($netu -band 255)
        return @{ Mac = $mac; Subnet = ('{0}/{1}' -f $netip, $len); Ip = $a.IPAddress }
    } catch { return $null }
}

function Test-RelayNetworkBound($Cfg) {
    $net = Get-RelayNetwork
    if ($null -eq $net) { return @($false, 'no default route') }
    foreach ($b in $Cfg.Networks) {
        if ([string](Get-CredoProp $b 'router_mac') -eq $net.Mac -and [string](Get-CredoProp $b 'subnet') -eq $net.Subnet) { return @($true, '') }
    }
    return @($false, ('current network (router ' + $net.Mac + ', ' + $net.Subnet + ') is not bound; run -Action Init on a trusted network'))
}

# --- relay state -------------------------------------------------------------------

function New-RelayLink($Peer) {
    return @{ Peer = $Peer; Key = $Peer.Key; Client = $null; Stream = $null; State = 'idle'; Task = $null; Buf = (New-Object byte[] 65536);
              Pending = (New-Object System.IO.MemoryStream); NextTry = [DateTime]::UtcNow; Fails = 0; LastRx = [DateTime]::UtcNow;
              LastTx = [DateTime]::UtcNow; RemoteInterval = 5.0; Machine = ''; Direction = 'out'; Src = '' }
}

function Close-RelayLink($R, $Link, [string]$Why) {
    if ($Link.State -eq 'up' -and $Why) { Write-RelayLog ('link ' + $Link.Key + ' down: ' + $Why) }
    try { if ($Link.Client) { $Link.Client.Close() } } catch {}
    $Link.Client = $null; $Link.Stream = $null; $Link.Task = $null
    $Link.Pending = New-Object System.IO.MemoryStream
    $Link.State = 'idle'
    $Link.Fails += 1
    $Link.NextTry = [DateTime]::UtcNow.AddSeconds([Math]::Min(60, 5 * [Math]::Pow(2, [Math]::Min($Link.Fails - 1, 3))))
}

function Send-RelayPayload($R, $Link, $Payload) {
    if ($null -eq $Link.Stream) { return $false }
    try {
        $b = $script:Utf8.GetBytes((New-RelayFrame $R.Cfg.Token $Payload) + "`n")
        $Link.Stream.Write($b, 0, $b.Length)
        $Link.LastTx = [DateTime]::UtcNow
        return $true
    } catch {
        Close-RelayLink $R $Link ('write failed: ' + $_.Exception.Message)
        return $false
    }
}

function New-RelayHello($R, [bool]$Ack) {
    $h = [ordered]@{ kind = 'link'; machine = $R.Cfg.Machine; listen_port = $R.Cfg.Port; roster_interval = $R.Cfg.Interval; nonce = $R.Nonce }
    if ($Ack) { $h['ack'] = $true } else { $h['chal'] = (New-CredoRandomHex 16) }
    return $h
}

function Get-RelayRoster($R) {
    $sessions = @()
    foreach ($o in (Get-CredoSessions $R.Hub.SessDir)) {
        $sid = [string](Get-CredoProp $o 'sessionId')
        if ($sid -notmatch '^[A-Za-z0-9._-]{1,128}$') { continue }
        $name = ''
        if ((Get-CredoProp $o 'nameSource') -eq 'user') { $name = ConvertTo-RelayCleanName ([string](Get-CredoProp $o 'name')) 20 }
        if (-not $name) { $name = Get-RelaySidShort $sid }
        $st = [string](Get-CredoProp $o 'status')
        if (-not $st) { $st = 'idle' }
        $sessions += ,([ordered]@{ sessionId = $sid; name = $name; status = $st; profile = '.claude' })
    }
    return [ordered]@{ kind = 'roster'; machine = $R.Cfg.Machine; harness = 'Claude Code'; network = ''; user = $env:USERNAME;
                       profile = '.claude'; listen_port = $R.Cfg.Port; sessions = $sessions }
}

function Invoke-RelayRoster($R, $Link, $P) {
    $machine = ConvertTo-RelayCleanName ([string](Get-CredoProp $P 'machine')) 60
    $Link.Machine = $machine
    $R.Seen[$Link.Key] = [DateTime]::UtcNow
    $local = @{}
    foreach ($o in (Get-CredoSessions $R.Hub.SessDir)) { $local[[string](Get-CredoProp $o 'sessionId')] = $true }
    $present = @{}
    foreach ($s in @(Get-CredoProp $P 'sessions')) {
        if ($null -eq $s -or $present.Count -ge $script:MaxRemotes) { continue }
        $sid = [string](Get-CredoProp $s 'sessionId')
        if ($sid -notmatch '^[A-Za-z0-9._-]{1,128}$' -or $local.ContainsKey($sid)) { continue }
        $owner = $R.SidOwner[$sid]
        if ($owner -and $owner -ne $Link.Key) { continue }
        $prof = [string](Get-CredoProp $s 'profile')
        if (-not $prof) { $prof = [string](Get-CredoProp $P 'profile') }
        $parts = @([string](Get-CredoProp $P 'harness'), [string](Get-CredoProp $P 'network'), $machine, [string](Get-CredoProp $P 'user'), $prof)
        if (-not $parts[0]) { $parts[0] = 'Claude Code' }
        $sname = [string](Get-CredoProp $s 'name')
        $present[$sid] = @{ sessionId = $sid; status = [string](Get-CredoProp $s 'status'); cwd = ''; version = '';
                            name = (Get-RelayMirrorName $parts $sname $sid); peerFeatures = @() }
    }
    foreach ($k in @($R.Hub.Mirrors.Keys)) {
        $m = $R.Hub.Mirrors[$k]
        if ($m.Extra.credoPeerLanPeer -eq $Link.Key -and -not $present.ContainsKey($m.Fields.sessionId)) {
            Remove-CredoMirror $R.Hub $k
            $R.SidOwner.Remove($m.Fields.sessionId)
        }
    }
    foreach ($sid in $present.Keys) {
        $key = $Link.Key + '|' + $sid
        $m = $R.Hub.Mirrors[$key]
        if ($null -eq $m) {
            $m = New-CredoMirror $R.Hub $key $present[$sid] @{ credoPeerLanFrom = $machine; credoPeerLanPeer = $Link.Key }
            if ($null -ne $m) { $R.SidOwner[$sid] = $Link.Key; Write-RelayLog ('remote up: ' + $present[$sid].name) }
        } else {
            Update-CredoMirror $R.Hub $m $present[$sid]
        }
    }
}

function Invoke-RelayDeliver($R, $Link, $P) {
    $target = [string](Get-CredoProp $P 'target_sessionId')
    $body = Get-CredoProp $P 'body'
    if ($body -isnot [string] -or (Test-RelayEnvelopeDelim $body)) {
        Write-RelayLog ('deliver from ' + $Link.Key + ' rejected: body contains an envelope delimiter or is not text')
        return
    }
    $dest = $null
    foreach ($o in (Get-CredoSessions $R.Hub.SessDir)) { if ([string](Get-CredoProp $o 'sessionId') -eq $target) { $dest = $o } }
    if ($null -eq $dest) { Write-RelayLog ('deliver: no live local session ' + $target + ', dropped'); return }
    $reply = $null
    $from = [string](Get-CredoProp $P 'from_sessionId')
    $rm = $R.Hub.Mirrors[$Link.Key + '|' + $from]
    if ($from -and $null -ne $rm) { $reply = $rm.PipePath }
    $env = New-RelayEnvelope $body ([string](Get-CredoProp $P 'from_name')) $reply
    $frame = [ordered]@{ type = 'user'; message = [ordered]@{ content = $env }; uuid = [guid]::NewGuid().ToString(); priority = 'next' }
    if ($reply) { $frame['from'] = 'uds:' + $reply }
    $bytes = $script:Utf8.GetBytes(($frame | ConvertTo-Json -Compress -Depth 5) + "`n")
    Start-CredoSend $R.Hub ([long](Get-CredoProp $dest 'pid')) ([string](Get-CredoProp $dest 'messagingSocketPath')) $bytes $target {
        param($i, $ok, $err)
        if ($ok) { Write-RelayLog ('deliver: injected into ' + $i) } else { Write-RelayLog ('deliver into ' + $i + ' failed: ' + $err) }
    }
}

function Invoke-RelayMirrorMessage($R, $Mirror, [byte[]]$Data) {
    # a local session wrote into the mirror of a remote session: one deliver per user
    # message line, over that peer's link
    $link = $R.Links | Where-Object { $_.Key -eq $Mirror.Extra.credoPeerLanPeer } | Select-Object -First 1
    if ($null -eq $link -or $link.State -ne 'up') { Write-RelayLog ('message to ' + $Mirror.Fields.name + ' dropped: no link to ' + $Mirror.Extra.credoPeerLanPeer); return }
    $local = Get-CredoSessions $R.Hub.SessDir
    foreach ($line in ($script:Utf8.GetString($Data) -split "`n")) {
        if (-not $line.Trim()) { continue }
        try { $f = $line | ConvertFrom-Json } catch { Write-RelayLog 'unparseable frame dropped'; continue }
        if ((Get-CredoProp $f 'type') -ne 'user') { continue }
        $content = [string](Get-CredoProp (Get-CredoProp $f 'message') 'content')
        $m = [regex]::Match($content, '<cross-session-message\b[^>]*>(.*)</cross-session-message>', 'Singleline')
        $body = if ($m.Success) { $m.Groups[1].Value.Trim() } else { $content }
        if (-not $body) { continue }
        $fromName = ''
        $nm = [regex]::Match($content, 'from-name="([^"]*)"')
        if ($nm.Success) { $fromName = $nm.Groups[1].Value }
        $fromSid = ''
        $addr = [string](Get-CredoProp $f 'from')
        if ($addr.StartsWith('uds:')) {
            $canon = Get-CredoCanonicalPipePath $addr.Substring(4)
            foreach ($o in $local) {
                if ($canon -and (Get-CredoCanonicalPipePath ([string](Get-CredoProp $o 'messagingSocketPath'))) -eq $canon) {
                    $fromSid = [string](Get-CredoProp $o 'sessionId')
                    if ((Get-CredoProp $o 'nameSource') -eq 'user') { $fromName = [string](Get-CredoProp $o 'name') }
                    elseif (-not $fromName) { $fromName = Get-RelaySidShort $fromSid }
                }
            }
        }
        $payload = [ordered]@{ kind = 'deliver'; target_sessionId = $Mirror.Fields.sessionId; from_sessionId = $fromSid;
                               from_name = (ConvertTo-RelayCleanName $fromName 20); body = $body }
        if (Send-RelayPayload $R $link $payload) { Write-RelayLog ('forwarded deliver to ' + $link.Key) }
    }
}

function Invoke-RelayLine($R, $Link, [string]$Line) {
    $p = Read-RelayFrame $R.Cfg.Token $Line
    if ($null -eq $p) { Write-RelayLog ('rejected unauthenticated/garbled frame from ' + $Link.Key); return }
    $kind = [string](Get-CredoProp $p 'kind')
    $Link.LastRx = [DateTime]::UtcNow
    if ($Link.State -eq 'hello') {
        if ($kind -eq 'link' -and (Get-CredoProp $p 'ack') -eq $true -and $null -eq (Get-CredoProp $p 'challenge')) {
            $Link.State = 'up'; $Link.Fails = 0
            $ri = Get-CredoProp $p 'roster_interval'
            if ($ri -is [int] -or $ri -is [double] -or $ri -is [long]) { $Link.RemoteInterval = [Math]::Max(1.0, [Math]::Min(60.0, [double]$ri)) }
            Write-RelayLog ('link ' + $Link.Key + ' up (' + (ConvertTo-RelayCleanName ([string](Get-CredoProp $p 'machine')) 60) + ')')
            [void](Send-RelayPayload $R $Link (Get-RelayRoster $R))
            return
        }
        $why = [string](Get-CredoProp $p 'refused')
        if (-not $why -and $null -ne (Get-CredoProp $p 'challenge')) { $why = 'the peer requires pairing (this relay does not pair; run pair-reset for this address on the peer)' }
        Close-RelayLink $R $Link ('link refused: ' + $why)
        Write-RelayLog ('link to ' + $Link.Key + ' refused: ' + $why)
        return
    }
    switch ($kind) {
        'roster' { try { Invoke-RelayRoster $R $Link $p } catch { Write-RelayLog ('roster failed: ' + $_.Exception.Message) } }
        'deliver' { try { Invoke-RelayDeliver $R $Link $p } catch { Write-RelayLog ('deliver failed: ' + $_.Exception.Message) } }
        'ping' { }
        'link' { }
        default { Write-RelayLog ('unknown message kind ' + $kind) }
    }
}

function Invoke-RelayLinkPoll($R, $Link) {
    $now = [DateTime]::UtcNow
    if ($Link.State -eq 'idle') {
        # loopback peers (same machine) need no bound network, like the Python relay
        if ($Link.Direction -ne 'out' -or $now -lt $Link.NextTry) { return }
        if (-not $R.Enabled -and $Link.Peer.Host -ne '127.0.0.1') { return }
        $Link.Client = New-Object System.Net.Sockets.TcpClient
        $Link.Task = $Link.Client.ConnectAsync($Link.Peer.Host, [int]$Link.Peer.Port)
        $Link.State = 'connecting'
        $Link.LastRx = $now
        return
    }
    if ($null -ne $Link.Task -and $Link.Task.IsCompleted) {
        if ($Link.Task.IsFaulted -or $Link.Task.IsCanceled) { Close-RelayLink $R $Link 'connection failed'; return }
        if ($Link.State -eq 'connecting') {
            $Link.Stream = $Link.Client.GetStream()
            $Link.Stream.WriteTimeout = 5000
            $Link.State = 'hello'
            $Link.LastRx = $now
            if (-not (Send-RelayPayload $R $Link (New-RelayHello $R $false))) { return }
            $Link.Task = $Link.Stream.ReadAsync($Link.Buf, 0, $Link.Buf.Length)
            return
        }
        $n = $Link.Task.Result
        if ($n -le 0) { Close-RelayLink $R $Link 'closed by peer'; return }
        $Link.Pending.Write($Link.Buf, 0, $n)
        if ($Link.Pending.Length -gt $script:MaxMessage) { Close-RelayLink $R $Link 'oversize frame'; return }
        $data = $Link.Pending.ToArray()
        $pos = 0
        while ($true) {
            $nl = Get-CredoIndexOfNewline $data $pos
            if ($nl -lt 0) { break }
            $line = $script:Utf8.GetString($data, $pos, $nl - $pos).Trim()
            $pos = $nl + 1
            if ($line) { Invoke-RelayLine $R $Link $line }
            if ($Link.State -eq 'idle') { return }
        }
        $Link.Pending = New-Object System.IO.MemoryStream
        if ($pos -lt $data.Length) { $Link.Pending.Write($data, $pos, $data.Length - $pos) }
        $Link.Task = $Link.Stream.ReadAsync($Link.Buf, 0, $Link.Buf.Length)
    }
    $silence = 3 * [Math]::Max($R.Cfg.Interval, $Link.RemoteInterval)
    if ($Link.State -ne 'idle' -and ($now - $Link.LastRx).TotalSeconds -gt [Math]::Min(60, [Math]::Max(15, $silence))) {
        Close-RelayLink $R $Link 'timeout, no traffic'
        return
    }
    if ($Link.State -eq 'up' -and ($now - $Link.LastTx).TotalSeconds -ge [Math]::Min(15, $R.Cfg.Interval)) {
        [void](Send-RelayPayload $R $Link ([ordered]@{ kind = 'ping' }))
    }
}

function Invoke-RelayInbound($R, $Client) {
    # optional listener: a link hello from a configured peer becomes that peer's link
    # (when we have none up); single frames (roster, deliver) on a fresh connection are
    # handled at once. Everything outside the allowlist is closed unread.
    $src = ([System.Net.IPEndPoint]$Client.Client.RemoteEndPoint).Address.ToString()
    if ($src.StartsWith('::ffff:')) { $src = $src.Substring(7) }
    $allow = @($R.Cfg.Allow) + @($R.Peers | ForEach-Object { $_.Host })
    if ((-not $R.Enabled -and $src -ne '127.0.0.1') -or -not (Test-RelayAllowed $src $allow)) { $Client.Close(); return }
    $stream = $Client.GetStream()
    $stream.ReadTimeout = 10000
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 65536
    $first = $null
    try {
        while ($ms.Length -lt $script:MaxMessage) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            $arr = $ms.ToArray()
            $nl = Get-CredoIndexOfNewline $arr 0
            if ($nl -ge 0 -and $null -eq $first) {
                $first = Read-RelayFrame $R.Cfg.Token ($script:Utf8.GetString($arr, 0, $nl))
                if ($null -ne $first -and (Get-CredoProp $first 'kind') -eq 'link') { break }
            }
        }
    } catch {}
    $peer = $R.Links | Where-Object { $_.Peer.Host -eq $src } | Select-Object -First 1
    if ($null -ne $first -and (Get-CredoProp $first 'kind') -eq 'link') {
        if ($null -eq $peer -or $peer.State -eq 'up' -or $null -ne (Get-CredoProp $first 'pid')) {
            # unknown source, a link already up, or a pairing hello (this relay never pairs)
            try { $b = $script:Utf8.GetBytes((New-RelayFrame $R.Cfg.Token ([ordered]@{ kind = 'link'; refused = 'refused'; machine = $R.Cfg.Machine })) + "`n"); $stream.Write($b, 0, $b.Length) } catch {}
            $Client.Close()
            return
        }
        try { $peer.Client.Close() } catch {}
        $peer.Client = $Client; $peer.Stream = $stream; $peer.Stream.WriteTimeout = 5000; $peer.State = 'up'; $peer.Fails = 0
        $peer.LastRx = [DateTime]::UtcNow
        [void](Send-RelayPayload $R $peer (New-RelayHello $R $true))
        [void](Send-RelayPayload $R $peer (Get-RelayRoster $R))
        $arr = $ms.ToArray(); $nl = Get-CredoIndexOfNewline $arr 0
        $peer.Pending = New-Object System.IO.MemoryStream
        if ($nl + 1 -lt $arr.Length) { $peer.Pending.Write($arr, $nl + 1, $arr.Length - $nl - 1) }
        $peer.Task = $stream.ReadAsync($peer.Buf, 0, $peer.Buf.Length)
        Write-RelayLog ('inbound link from ' + $src + ' up')
        return
    }
    $Client.Close()
    if ($null -eq $peer) { return }
    foreach ($line in ($script:Utf8.GetString($ms.ToArray()) -split "`n")) { if ($line.Trim()) { Invoke-RelayLine $R $peer $line.Trim() } }
}

function Start-Relay {
    $cfg = Read-RelayConfig
    if ($null -eq $cfg) { Write-Output ('no config at ' + (Get-RelayConfigPath) + ' - run -Action Init first'); exit 1 }
    $mutex = New-Object System.Threading.Mutex($false, (Get-RelayMutexName))
    if (-not $mutex.WaitOne(0)) { Write-Output 'another credo-peer-lan-win relay is already running'; exit 0 }
    $stopFile = Join-Path (Get-RelayStateDir) 'peer-lan-win.stop'
    if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile -Force }
    $sessDir = Get-CredoSessionsDir
    if (-not (Test-Path -LiteralPath $sessDir)) { [void](New-Item -ItemType Directory -Path $sessDir -Force) }
    $R = @{ Cfg = $cfg; Nonce = (New-CredoRandomHex 8); Seen = @{}; SidOwner = @{}; Enabled = $false; Links = @() }
    $R.Hub = New-CredoHub $sessDir 'credoPeerLan' { param($m, [byte[]]$d) Invoke-RelayMirrorMessage $R $m $d } { param($t) Write-RelayLog $t }
    $R.Peers = Get-RelayPeerList $cfg
    $R.Links = @($R.Peers | ForEach-Object { New-RelayLink $_ })
    Remove-CredoStaleMirrors $R.Hub
    Start-CredoWatchdog $R.Hub
    $listener = $null
    $acceptTask = $null
    if ($cfg.Listen) {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $cfg.Port)
        $listener.Start()
        $acceptTask = $listener.AcceptTcpClientAsync()
    }
    Write-RelayLog ('relay up: machine ' + $cfg.Machine + ', ' + $R.Links.Count + ' peer(s), listen ' + $cfg.Listen)
    $nextNet = [DateTime]::MinValue
    $nextRoster = [DateTime]::UtcNow
    $nextHolders = [DateTime]::UtcNow.AddSeconds(10)
    try {
        while (-not (Test-Path -LiteralPath $stopFile)) {
            $now = [DateTime]::UtcNow
            if ($now -ge $nextNet) {
                $nextNet = $now.AddSeconds(30)
                $st = Test-RelayNetworkBound $cfg
                if ($st[0] -ne $R.Enabled) {
                    $R.Enabled = $st[0]
                    if ($R.Enabled) { Write-RelayLog 'network bound: LAN enabled' } else {
                        Write-RelayLog ('LAN disabled: ' + $st[1])
                        foreach ($l in $R.Links) {
                            if ($l.Peer.Host -eq '127.0.0.1') { continue }
                            if ($l.State -ne 'idle') { Close-RelayLink $R $l 'network no longer allowed' }
                            foreach ($mk in @($R.Hub.Mirrors.Keys)) {
                                $m = $R.Hub.Mirrors[$mk]
                                if ($m.Extra.credoPeerLanPeer -eq $l.Key) { $R.SidOwner.Remove($m.Fields.sessionId); Remove-CredoMirror $R.Hub $mk }
                            }
                        }
                    }
                }
            }
            $tasks = Get-CredoHubTasks $R.Hub
            foreach ($l in $R.Links) { if ($null -ne $l.Task) { [void]$tasks.Add($l.Task) } }
            if ($null -ne $acceptTask) { [void]$tasks.Add($acceptTask) }
            Wait-CredoTasks $tasks 250
            if ($null -ne $acceptTask -and $acceptTask.IsCompleted) {
                if (-not $acceptTask.IsFaulted) { try { Invoke-RelayInbound $R $acceptTask.Result } catch { Write-RelayLog ('inbound failed: ' + $_.Exception.Message) } }
                $acceptTask = $listener.AcceptTcpClientAsync()
            }
            foreach ($l in $R.Links) { try { Invoke-RelayLinkPoll $R $l } catch { Close-RelayLink $R $l ('error: ' + $_.Exception.Message) } }
            try { Invoke-CredoHubPoll $R.Hub } catch { Write-RelayLog ('poll failed: ' + $_.Exception.Message) }
            $now = [DateTime]::UtcNow
            if ($now -ge $nextRoster) {
                $nextRoster = $now.AddSeconds($cfg.Interval)
                foreach ($l in $R.Links) { if ($l.State -eq 'up') { [void](Send-RelayPayload $R $l (Get-RelayRoster $R)) } }
                foreach ($k in @($R.Seen.Keys)) {
                    if (($now - $R.Seen[$k]).TotalSeconds -gt $script:MachineTimeout) {
                        foreach ($mk in @($R.Hub.Mirrors.Keys)) {
                            $m = $R.Hub.Mirrors[$mk]
                            if ($m.Extra.credoPeerLanPeer -eq $k) { $R.SidOwner.Remove($m.Fields.sessionId); Remove-CredoMirror $R.Hub $mk }
                        }
                        $R.Seen.Remove($k)
                    }
                }
            }
            if ($now -ge $nextHolders) { $nextHolders = $now.AddSeconds(10); Test-CredoHolders $R.Hub }
        }
    } finally {
        foreach ($l in $R.Links) {
            if ($l.State -eq 'up') { [void](Send-RelayPayload $R $l ([ordered]@{ kind = 'ping'; bye = 'daemon shutdown' })) }
            try { if ($l.Client) { $l.Client.Close() } } catch {}
        }
        if ($null -ne $listener) { $listener.Stop() }
        Remove-CredoAllMirrors $R.Hub
        Write-RelayLog 'relay stopped'
        $mutex.ReleaseMutex()
    }
}

# --- CLI actions -------------------------------------------------------------------

function Save-RelayConfig($Obj) {
    $p = Get-RelayConfigPath
    $dir = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    Write-CredoFileAtomic $p ($Obj | ConvertTo-Json -Depth 6)
}

function Invoke-RelayInit {
    $old = Read-CredoJsonFile (Get-RelayConfigPath)
    $cfg = [ordered]@{
        this_machine    = if ($Machine) { $Machine } elseif ($old -and (Get-CredoProp $old 'this_machine')) { [string]$old.this_machine } else { [System.Net.Dns]::GetHostName().ToLowerInvariant() }
        listen_port     = if ($Port -gt 0) { $Port } elseif ($old -and (Get-CredoProp $old 'listen_port')) { [int]$old.listen_port } else { $script:DefaultPort }
        peers           = if ($Peers) { @($Peers) } elseif ($old) { @(Get-CredoProp $old 'peers') } else { @() }
        allow           = if ($Allow) { @($Allow) } elseif ($old) { @(Get-CredoProp $old 'allow' | Where-Object { $null -ne $_ }) } else { @() }
        listen          = if ($Listen) { $true } elseif ($NoListen) { $false } elseif ($old) { ((Get-CredoProp $old 'listen') -eq $true) } else { $false }
        roster_interval = 5
        token           = if ($old) { [string](Get-CredoProp $old 'token') } else { '' }
        networks        = if ($old) { @(Get-CredoProp $old 'networks' | Where-Object { $null -ne $_ }) } else { @() }
    }
    foreach ($p in @($cfg.peers)) {
        $h = ($p -split ':')[0]
        if (-not (Test-RelayPrivateIp $h)) { Write-Output ('refused: peer ' + $p + ' is not a private IPv4 address'); exit 1 }
    }
    foreach ($a in @($cfg.allow)) { if (-not (Test-RelayAllowEntry $a)) { Write-Output ('refused: allow entry ' + $a + ' (private IPv4 or CIDR /8../32 only)'); exit 1 } }
    $net = Get-RelayNetwork
    if ($null -eq $net) { Write-Output 'no default route: cannot bind the current network'; exit 1 }
    if (-not (@($cfg.networks) | Where-Object { $_.router_mac -eq $net.Mac -and $_.subnet -eq $net.Subnet })) {
        $cfg.networks = @($cfg.networks) + @([ordered]@{ router_mac = $net.Mac; subnet = $net.Subnet })
    }
    Save-RelayConfig $cfg
    Write-Output ('config written: ' + (Get-RelayConfigPath))
    Write-Output ('this machine: ' + $cfg.this_machine + ', address for the peers: ' + $net.Ip + ', bound network: ' + $net.Subnet)
    Write-Output ('peers: ' + (@($cfg.peers) -join ', '))
    Write-Output ('On every peer (Linux / WSL relay) add this machine once: credo-peer-lan.py init ' + $net.Ip + ' (and allow it in the bound network).')
}

function Invoke-RelayToken {
    $p = Get-RelayConfigPath
    $o = Read-CredoJsonFile $p
    if ($null -eq $o) { Write-Output 'no config - run -Action Init first'; exit 1 }
    $h = [ordered]@{}
    foreach ($pr in $o.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
    if ($Clear) { $h['token'] = '' } else {
        $sec = Read-Host -AsSecureString 'shared relay token (same on every machine; input hidden)'
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $h['token'] = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    }
    Save-RelayConfig $h
    Write-Output ('token ' + $(if ($Clear) { 'cleared' } else { 'set' }) + ' (restart the relay: -Action Stop, then the task restarts it at the next logon or run -Action Install again)')
}

function Invoke-RelayInstall {
    $dst = Join-Path (Get-RelayStateDir) 'peer-lan-win'
    if (-not (Test-Path -LiteralPath $dst)) { [void](New-Item -ItemType Directory -Path $dst -Force) }
    foreach ($f in 'credo-peer-lan-win.ps1', 'credo-win-common.ps1') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination (Join-Path $dst $f) -Force }
    $script = Join-Path $dst 'credo-peer-lan-win.ps1'
    $args2 = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script + '" -Action Run'
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args2
    $trg = New-ScheduledTaskTrigger -AtLogOn -User ($env:USERDOMAIN + '\' + $env:USERNAME)
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $script:TaskName -Action $act -Trigger $trg -Settings $set -Force `
        -Description 'credo LAN peer relay for native Windows Claude Code sessions (per user)' | Out-Null
    Start-ScheduledTask -TaskName $script:TaskName
    Write-Output ('installed: task ' + $script:TaskName + ' runs ' + $script + ' at logon (started now)')
}

function Invoke-RelayUninstall {
    New-Item -ItemType File -Path (Join-Path (Get-RelayStateDir) 'peer-lan-win.stop') -Force | Out-Null
    Start-Sleep -Seconds 2
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
    }
    $dst = Join-Path (Get-RelayStateDir) 'peer-lan-win'
    foreach ($f in 'credo-peer-lan-win.ps1', 'credo-win-common.ps1') {
        $p = Join-Path $dst $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    if ((Test-Path -LiteralPath $dst) -and -not (Get-ChildItem -LiteralPath $dst)) { Remove-Item -LiteralPath $dst -Force }
    Write-Output 'uninstalled (the config file is kept)'
}

function Invoke-RelayStatus {
    $cfg = Read-RelayConfig
    if ($null -eq $cfg) { Write-Output ('no config (' + (Get-RelayConfigPath) + ')'); return }
    Write-Output ('machine: ' + $cfg.Machine + '  port: ' + $cfg.Port + '  listen: ' + $cfg.Listen + '  token: ' + $(if ($cfg.Token) { 'set' } else { 'none' }))
    Write-Output ('peers: ' + ($cfg.Peers -join ', '))
    $st = Test-RelayNetworkBound $cfg
    Write-Output ('network: ' + $(if ($st[0]) { 'bound (LAN enabled)' } else { 'DISABLED - ' + $st[1] }))
    $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    Write-Output ('task: ' + $(if ($t) { [string]$t.State } else { 'not installed' }))
    $m = New-Object System.Threading.Mutex($false, (Get-RelayMutexName))
    $free = $m.WaitOne(0)
    if ($free) { $m.ReleaseMutex() }
    Write-Output ('relay: ' + $(if ($free) { 'not running' } else { 'running' }))
    Write-Output ('log: ' + (Join-Path (Get-RelayStateDir) 'peer-lan-win.log'))
}

if ($MyInvocation.InvocationName -ne '.') {
    switch ($Action) {
        'Run' { Start-Relay }
        'Init' { Invoke-RelayInit }
        'Token' { Invoke-RelayToken }
        'Install' { Invoke-RelayInstall }
        'Uninstall' { Invoke-RelayUninstall }
        'Status' { Invoke-RelayStatus }
        'Stop' { New-Item -ItemType File -Path (Join-Path (Get-RelayStateDir) 'peer-lan-win.stop') -Force | Out-Null; Write-Output 'stop requested' }
    }
}

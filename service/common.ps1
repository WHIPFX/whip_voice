# ============================================
# whip_voice - the pieces the setup wizard (install.ps1) and the check (check.ps1) share
# ============================================
#
# Dot-sourced by both ( . "$PSScriptRoot\common.ps1" ). It does nothing on its own. Windows PowerShell 5.1.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:VoiceMarker = '# whip_voice: the voice server (LiveKit). Added by whip_voice\service\install.ps1.'
$script:FwUdp       = 'ALLOW LiveKit voice UDP 7882-7893 (whip_voice)'
$script:FwTcp       = 'ALLOW LiveKit voice TCP 7881 (whip_voice)'
$script:FwCaddy     = 'ALLOW Caddy HTTP and HTTPS (whip_voice)'
$script:FwCaddyUdp  = 'ALLOW Caddy HTTP/3 (whip_voice)'

# --- Printing ------------------------------------------------------------------------------------
function Say($text, $color) { if ($color) { Write-Host $text -ForegroundColor $color } else { Write-Host $text } }
function Step($text) { Say ''; Say "== $text" 'Cyan' }
function Good($text) { Say "  [ OK ] $text" 'Green' }
function Warn($text) { Say "  [WARN] $text" 'Yellow' }
function Bad($text)  { Say "  [FAIL] $text" 'Red' }
function Fix($text)  { Say "         Fix: $text" 'Gray' }

function Test-Admin {
    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- NSSM (runs a program as a Windows service) ---------------------------------------------------
function Find-Nssm([string]$alsoIn = '') {
    $places = @('C:\Caddy\tools\nssm\nssm-2.24\win64\nssm.exe', 'C:\LiveKit\tools\nssm\nssm-2.24\win64\nssm.exe',
                'C:\KickSubathonTimer\tools\nssm\nssm-2.24\win64\nssm.exe')
    if ($alsoIn) { $places += (Join-Path $alsoIn 'tools\nssm\nssm-2.24\win64\nssm.exe') }
    foreach ($p in $places) { if (Test-Path $p) { return $p } }
    return $null
}

#--- One setting of an NSSM service (NSSM answers in UTF-16: the NULs are taken out).
function Get-NssmValue([string]$nssm, [string]$service, [string]$name) {
    if (-not $nssm) { return '' }
    $raw = (& cmd.exe /c "`"$nssm`" get $service $name 2>nul") -join ''
    return ($raw -replace "`0", '').Trim()
}

# --- This server's address -------------------------------------------------------------------------
function Get-NicIp {
    $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } | Select-Object -First 1
    if ($cfg) { return $cfg.IPv4Address[0].IPAddress }
    return $null
}

#--- The address the internet sees this server at (asked of public "what is my IP" services).
function Get-ExternalIp {
    foreach ($u in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
        try {
            $t = "$((Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 6).Content)".Trim()
            if ($t -match '^\d{1,3}(\.\d{1,3}){3}$') { return $t }
        } catch { }
    }
    return $null
}

function Test-PrivateIp([string]$ip) { return $ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.|169\.254\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)' }

#--- Does this look like one of Cloudflare's addresses (its orange-cloud proxy)?
function Test-CloudflareIp([string]$ip) {
    return $ip -match '^(104\.(1[6-9]|2\d|3[01])\.|172\.(6[4-9]|7[01])\.|188\.114\.(9[6-9]|10\d|11[01])\.|162\.15[89]\.|141\.101\.|108\.162\.|173\.245\.|198\.41\.|190\.93\.|197\.234\.|131\.0\.7[2-5]\.|103\.(21\.24[4-7]|22\.20[0-3]|31\.[4-7])\.)'
}

#--- What a name points at, asked of public DNS servers (not this machine's cache). Call it as
#--- @(Resolve-Public $name): a list, even of one.
function Resolve-Public([string]$name) {
    $ips = @()
    foreach ($server in @('1.1.1.1', '8.8.8.8')) {
        try {
            $r = Resolve-DnsName -Name $name -Type A -Server $server -DnsOnly -QuickTimeout -ErrorAction Stop
            $ips = @($r | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
        } catch { }
        if ($ips.Count -gt 0) { break }
    }
    return @($ips | Select-Object -Unique)
}

#--- A domain name as typed or pasted, cleaned (no https://, no path), or $null when it is not one.
function Get-CleanDomain([string]$text) {
    $d = "$text".Trim().ToLower()
    $d = $d -replace '^(https?|wss?)://', ''
    $d = ($d -split '[/:]')[0]
    if ($d -match '^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$') { return $d }
    return $null
}

#--- An IPv4 address (four numbers 0-255)?
function Test-IPv4([string]$text) {
    if ("$text" -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($n in "$text".Split('.')) { if ([int]$n -gt 255) { return $false } }
    return $true
}

#--- A voice address as typed or pasted: this server's IPv4 (players' games connect to it directly) or a domain name,
#--- cleaned (no wss://, no path, no port), or $null when it is neither.
function Get-CleanAddress([string]$text) {
    $d = "$text".Trim().ToLower() -replace '^(https?|wss?)://', ''
    $d = ($d -split '[/:]')[0]
    if (Test-IPv4 $d) { return $d }
    return Get-CleanDomain $d
}

#--- The Caddyfile site the wizard writes for a voice address, with its marker line in front. A domain gets Caddy's
#--- usual certificate. An IP address gets one from Let's Encrypt's "shortlived" profile, the only kind issued for an
#--- IP: it lasts about 6 days, and Caddy renews it by itself every few days.
function New-VoiceSiteBlock([string]$address) {
    $nl = "`r`n"
    $site = "$address {$nl"
    if (Test-IPv4 $address) {
        $site += "`ttls {$nl`t`tissuer acme {$nl`t`t`tdir https://acme-v02.api.letsencrypt.org/directory$nl`t`t`tprofile shortlived$nl`t`t}$nl`t}$nl"
    }
    $site += "`treverse_proxy 127.0.0.1:7880$nl}$nl"
    return "$($script:VoiceMarker)$nl$site"
}

#--- A Caddyfile's text without the wizard's own voice site (its marker line and the site block under it, braces
#--- counted). Anything else in the file stays as it is. Answers { Text, Removed }.
function Remove-VoiceSiteBlock([string]$text) {
    $lines = $text -split "\r?\n"
    $out = New-Object 'System.Collections.Generic.List[string]'
    $removed = $false
    $i = 0
    while ($i -lt $lines.Count) {
        if ($lines[$i].Trim() -eq $script:VoiceMarker -and $i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s*[A-Za-z0-9.-]+\s*\{\s*$') {
            $depth = 0
            $j = $i + 1
            do {
                $depth += ([regex]::Matches($lines[$j], '\{')).Count - ([regex]::Matches($lines[$j], '\}')).Count
                $j++
            } while ($depth -gt 0 -and $j -lt $lines.Count)
            $i = $j
            $removed = $true
            continue
        }
        $out.Add($lines[$i])
        $i++
    }
    return [pscustomobject]@{ Text = (($out -join "`r`n").TrimEnd() + "`r`n"); Removed = $removed }
}

# --- Ports -----------------------------------------------------------------------------------------
#--- Who listens on a port: { ProcessId, Name, Path } or $null.
function Get-PortOwner([int]$port, [string]$proto = 'TCP') {
    if ($proto -eq 'TCP') { $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1 }
    else { $c = Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $c) { return $null }
    $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    $name = '?'; $path = ''
    if ($p) { $name = $p.ProcessName; $path = "$($p.Path)" }
    if ($c.OwningProcess -eq 4) { $name = 'Windows HTTP service (IIS or http.sys)' }
    return [pscustomobject]@{ ProcessId = $c.OwningProcess; Name = $name; Path = $path }
}

# --- Caddy -----------------------------------------------------------------------------------------
#--- The Caddy already on this machine: { Exe, Caddyfile, Service, Dir }, or $null for none.
function Find-Caddy([string]$defaultDir = 'C:\Caddy') {
    $svc = Get-Service -Name 'caddy' -ErrorAction SilentlyContinue
    if ($svc) {
        $exe = ''; $cfgPath = ''
        $nssm = Find-Nssm
        $app = Get-NssmValue $nssm 'caddy' 'Application'
        if ($app -and $app -match 'caddy\.exe$') {
            $exe = $app
            $params = Get-NssmValue $nssm 'caddy' 'AppParameters'
            if ($params -match '--config\s+("([^"]+)"|(\S+))') { $cfgPath = if ($matches[2]) { $matches[2] } else { $matches[3] } }
        } else {
            # Not NSSM's: Caddy's own service, its command line in the service's path.
            $w = Get-CimInstance Win32_Service -Filter "Name='caddy'" -ErrorAction SilentlyContinue
            if ($w -and $w.PathName -match '"?([^"]*caddy\.exe)"?') { $exe = $matches[1] }
            if ($w -and $w.PathName -match '--config\s+("([^"]+)"|(\S+))') { $cfgPath = if ($matches[2]) { $matches[2] } else { $matches[3] } }
        }
        if ($exe) {
            $dir = Split-Path $exe -Parent
            if (-not $cfgPath) { $cfgPath = Join-Path $dir 'Caddyfile' }
            return [pscustomobject]@{ Exe = $exe; Caddyfile = $cfgPath; Service = 'caddy'; Dir = $dir }
        }
    }
    $exe = Join-Path $defaultDir 'caddy.exe'
    if (Test-Path $exe) {
        return [pscustomobject]@{ Exe = $exe; Caddyfile = (Join-Path $defaultDir 'Caddyfile'); Service = $null; Dir = $defaultDir }
    }
    $cmd = Get-Command caddy.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        $dir = Split-Path $cmd.Source -Parent
        return [pscustomobject]@{ Exe = $cmd.Source; Caddyfile = (Join-Path $dir 'Caddyfile'); Service = $null; Dir = $dir }
    }
    return $null
}

#--- The voice address a Caddyfile already serves (the installer's site, or any site in front of LiveKit).
function Get-VoiceSite([string]$caddyfile) {
    if (-not $caddyfile -or -not (Test-Path $caddyfile)) { return $null }
    $text = [IO.File]::ReadAllText($caddyfile)
    $m = [regex]::Match($text, '(?m)^' + [regex]::Escape($script:VoiceMarker) + '\s*\r?\n\s*([A-Za-z0-9.-]+)\s*\{')
    if ($m.Success) { return $m.Groups[1].Value.ToLower() }
    $m = [regex]::Match($text, '(?ms)^\s*([A-Za-z0-9.-]+\.[A-Za-z]{2,})\s*\{[^{}]*reverse_proxy\s+(localhost|127\.0\.0\.1):7880')
    if ($m.Success) { return $m.Groups[1].Value.ToLower() }
    return $null
}

# --- LiveKit ---------------------------------------------------------------------------------------
#--- The version a livekit-server.exe says it is ('1.13.7'), or $null (none there, or it would not say).
function Get-LiveKitVersion([string]$exe) {
    if (-not $exe -or -not (Test-Path $exe)) { return $null }
    $out = (& cmd.exe /c "`"$exe`" --version 2>&1") -join ' '
    if ($out -match 'version\s+v?(\d+\.\d+\.\d+)') { return $matches[1] }
    return $null
}

# --- LiveKit's config ------------------------------------------------------------------------------
#--- { Key, Secret, NodeIp } from C:\LiveKit\config.yaml; Unreadable when only an administrator may read it.
function Read-LiveKitConfig([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { $text = [IO.File]::ReadAllText($path) } catch { return [pscustomobject]@{ Unreadable = $true } }
    $out = [pscustomobject]@{ Unreadable = $false; Key = $null; Secret = $null; NodeIp = $null }
    $k = [regex]::Match($text, '(?m)^\s{2}(whip[A-Za-z0-9]+):\s*([A-Za-z0-9]+)\s*$')
    if ($k.Success) { $out.Key = $k.Groups[1].Value; $out.Secret = $k.Groups[2].Value }
    $n = [regex]::Match($text, '(?m)^\s*node_ip:\s*(\S+)')
    if ($n.Success) { $out.NodeIp = $n.Groups[1].Value }
    return $out
}

# --- HTTPS -----------------------------------------------------------------------------------------
#--- The certificate an address serves on port 443: { Ok (valid for it), NotAfter, Issuer, Why }. For an IP address no
#--- name is sent (no SNI), as a player's game connecting to wss://<ip> sends none.
function Get-HttpsCertificate([string]$address) {
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $wait = $tcp.BeginConnect($address, 443, $null, $null)
        if (-not $wait.AsyncWaitHandle.WaitOne(6000)) { return [pscustomobject]@{ Ok = $false; NotAfter = $null; Issuer = ''; Why = 'no answer on port 443' } }
        $tcp.EndConnect($wait)
        $script:certErrors = 'None'
        $callback = [Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $errors) $script:certErrors = "$errors"; return $true }
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, $callback)
        $ssl.ReadTimeout = 6000; $ssl.WriteTimeout = 6000
        # TLS 1.2 by name: Windows PowerShell 5.1's default here is older, and Caddy refuses it.
        $ssl.AuthenticateAsClient($address, $null, [Security.Authentication.SslProtocols]::Tls12, $false)
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $ssl.Dispose()
        $why = ''
        if ($script:certErrors -ne 'None') { $why = "the certificate is not valid for $address ($($script:certErrors))" }
        return [pscustomobject]@{ Ok = ($script:certErrors -eq 'None'); NotAfter = $cert.NotAfter; Issuer = $cert.Issuer; Why = $why }
    } catch {
        return [pscustomobject]@{ Ok = $false; NotAfter = $null; Issuer = ''; Why = $_.Exception.Message }
    } finally { $tcp.Close() }
}

#--- GET https://<address>/ : { Ok, Status, Body, Why }. Ok = a valid certificate and LiveKit's "OK".
function Test-Https([string]$domain) {
    try {
        $r = Invoke-WebRequest -Uri "https://$domain/" -UseBasicParsing -TimeoutSec 10
        $body = "$($r.Content)".Trim()
        return [pscustomobject]@{ Ok = ($r.StatusCode -eq 200 -and $body -eq 'OK'); Status = [int]$r.StatusCode; Body = $body; Why = '' }
    } catch [System.Net.WebException] {
        $e = $_.Exception
        $status = 0
        if ($e.Response) { $status = [int]$e.Response.StatusCode }
        return [pscustomobject]@{ Ok = $false; Status = $status; Body = ''; Why = "$($e.Status): $($e.Message)" }
    } catch {
        return [pscustomobject]@{ Ok = $false; Status = 0; Body = ''; Why = $_.Exception.Message }
    }
}

# --- server.cfg ------------------------------------------------------------------------------------
#--- A path dragged into the window comes with quotes round it; an empty answer is no path.
function Get-CleanPath([string]$text) {
    $p = "$text".Trim().Trim('"').Trim("'")
    if ($p -eq '') { return $null }
    return $p
}

# An `ensure` line of one resource, with or without a comment after it ("ensure whip_voice   # voice").
$script:EndOfName = '(\s*$|\s+(#|//))'

#--- What server.cfg says about voice: { Url, Key, Secret, BotToken, Public (a name set with setr/sets: every player
#--- can read it), EnsureVoice (ensure whip_voice, or of a [folder] in $categories it sits in), Mumble (sv_mumble on) }.
#--- Comment lines are ignored.
function Read-ServerCfgVoice([string]$path, [string[]]$categories = @()) {
    $out = [pscustomobject]@{ Url = $null; Key = $null; Secret = $null; BotToken = $null; Public = @(); EnsureVoice = $false; Mumble = $false }
    foreach ($l in [IO.File]::ReadAllLines($path)) {
        $t = $l.Trim()
        if ($t.StartsWith('#') -or $t.StartsWith('//')) { continue }
        $m = [regex]::Match($t, '^(set|setr|sets)\s+whip_voice_(url|key|secret)\s+"?([^"\s]*)"?')
        if ($m.Success) {
            $value = $m.Groups[3].Value
            switch ($m.Groups[2].Value) { 'url' { $out.Url = $value } 'key' { $out.Key = $value } 'secret' { $out.Secret = $value } }
            if ($m.Groups[1].Value -ne 'set') { $out.Public += "whip_voice_$($m.Groups[2].Value)" }
            continue
        }
        $m = [regex]::Match($t, '^(set|setr|sets)\s+whip_voicebot_token\s+"?([^"\s]*)"?')
        if ($m.Success) {
            $out.BotToken = $m.Groups[2].Value
            if ($m.Groups[1].Value -ne 'set') { $out.Public += 'whip_voicebot_token' }
            continue
        }
        if ($t -match ('^(ensure|start)\s+whip_voice' + $script:EndOfName)) { $out.EnsureVoice = $true }
        foreach ($c in $categories) { if ($t -match ('^(ensure|start)\s+' + [regex]::Escape($c) + $script:EndOfName)) { $out.EnsureVoice = $true } }
        if ($t -match '^(set|setr|sets)\s+sv_mumble\s+"?(true|1)"?') { $out.Mumble = $true }
    }
    return $out
}

#--- The [folders] between "resources" and whip_voice (a server made by WHIP's recipe has none): the `ensure` of one starts it too.
function Get-VoiceCategories([string]$from) {
    $names = @()
    $d = Get-Item -LiteralPath $from -ErrorAction SilentlyContinue
    while ($d -and $d.Name -ine 'resources') {
        if ($d.Name -match '^\[.+\]$') { $names += $d.Name }
        $d = $d.Parent
    }
    if (-not $d) { return @() }   # not inside a resources folder
    return $names
}

#--- The server.cfg of the FiveM server this whip_voice is in: the one in the folder above "resources" (txAdmin's
#--- profile folder, or server-data). Answers its path, or $null when there is none to find.
function Find-ServerCfg([string]$from) {
    $d = Get-Item -LiteralPath $from -ErrorAction SilentlyContinue
    while ($d) {
        if ($d.Name -ieq 'resources' -and $d.Parent) {
            $cfg = Join-Path $d.Parent.FullName 'server.cfg'
            if (Test-Path -LiteralPath $cfg) { return $cfg }
            return $null
        }
        $d = $d.Parent
    }
    return $null
}

#--- Put whip_voice's lines into server.cfg: the old url/key/secret lines out, the new ones in, and an sv_mumble line
#--- turned off. They go before whatever starts whip_voice (`ensure whip_voice`, or the `ensure` of a folder it is in), so
#--- it has them when it starts; with neither, after `ensure whip_core` (else at the end) with `ensure whip_voice`.
#--- With a voice bot token, its line too (without one, a voice bot line already there is left as it is). A backup is
#--- kept beside it. $categories: the [folders] whip_voice sits in (Get-VoiceCategories). Answers { Backup, Notes }.
#--- Never prints the secret.
function Update-ServerCfg([string]$path, [string]$url, [string]$key, [string]$secret, [string]$botToken = '', [string[]]$categories = @()) {
    $text = [IO.File]::ReadAllText($path)
    $nl = "`n"
    if ($text -match "`r`n") { $nl = "`r`n" }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $notes = @()
    $insertAt = -1      # the first line that starts whip_voice
    $coreAt = -1        # the line that starts whip_core
    $voiceSeen = $false
    foreach ($l in ($text -split "\r?\n")) {
        $t = $l.Trim()
        if ($t -match '^(set|setr|sets)\s+whip_voice_(url|key|secret)\b') {
            $notes += "replaced the old whip_voice_$($matches[2]) line"
            continue
        }
        if ($botToken -and $t -match '^(set|setr|sets)\s+whip_voicebot_token\b') {
            $notes += 'replaced the old whip_voicebot_token line'
            continue
        }
        if ($t -match '^#\s*whip_voice(: the advanced voice system| \(set by its setup wizard\))') { continue }   # our own heading, from a run before
        # FiveM's own Mumble voice, which whip_voice does not use. Left on, any player's game can listen to any
        # Mumble channel.
        if ($t -match '^(set|setr|sets)\s+sv_mumble\s+"?(true|1)"?') {
            $lines.Add("# $t   # off: whip_voice does not use it (insecure)")
            $notes += 'turned off sv_mumble (whip_voice does not use it)'
            continue
        }
        if ($t -match ('^(ensure|start)\s+whip_voice' + $script:EndOfName)) {
            # The first one stays; a second one would start it twice.
            if ($voiceSeen) { $notes += 'took out a second "ensure whip_voice"'; continue }
            $voiceSeen = $true
            if ($insertAt -lt 0) { $insertAt = $lines.Count }
            $lines.Add($l)
            continue
        }
        # A folder whip_voice sits in (its folder's `ensure`) starts it too.
        foreach ($c in $categories) {
            if ($insertAt -lt 0 -and $t -match ('^(ensure|start)\s+' + [regex]::Escape($c) + $script:EndOfName)) { $insertAt = $lines.Count }
        }
        if ($coreAt -lt 0 -and $t -match ('^(ensure|start)\s+whip_core' + $script:EndOfName)) { $coreAt = $lines.Count }
        $lines.Add($l)
    }
    $block = @(
        '# whip_voice (set by its setup wizard). Plain "set", never "setr": the secret stays on the server.',
        "set whip_voice_url    `"$url`"",
        "set whip_voice_key    `"$key`"",
        "set whip_voice_secret `"$secret`""
    )
    if ($botToken) { $block += "set whip_voicebot_token `"$botToken`"" }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -eq '') { $lines.RemoveAt($lines.Count - 1) }
    if ($insertAt -ge 0) {
        $lines.InsertRange($insertAt, [string[]]$block)
    } elseif ($coreAt -ge 0) {
        $lines.InsertRange($coreAt + 1, [string[]]($block + 'ensure whip_voice'))
        $notes += 'added "ensure whip_voice" after "ensure whip_core"'
    } else {
        $lines.Add('')
        $lines.AddRange([string[]]$block)
        $lines.Add('ensure whip_voice')
        $notes += 'added "ensure whip_voice" at the end'
    }
    $backup = "$path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $path $backup
    [IO.File]::WriteAllText($path, (($lines -join $nl) + $nl), (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Backup = $backup; Notes = $notes }
}

# --- The voice bot (lore characters phoning players) ---------------------------------------------------
#--- Its config.json: { Unreadable, Token, Data (the whole file) }, or $null when there is none. Locked to
#--- administrators and the service, so anyone else reads Unreadable.
function Read-VoiceBotConfig([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { $data = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return [pscustomobject]@{ Unreadable = $true; Token = $null; Data = $null } }
    $token = $null
    if ($data -and $data.token -is [string]) { $token = $data.token }
    return [pscustomobject]@{ Unreadable = $false; Token = $token; Data = $data }
}

#--- Ask the voice bot how it is: { Ok, Status (401: it refused the token), Version, Calls, Max }.
function Test-VoiceBot([string]$token, [int]$port = 7899) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing -TimeoutSec 4
        $h = "$($r.Content)" | ConvertFrom-Json
        return [pscustomobject]@{ Ok = ($h.ok -eq $true); Status = [int]$r.StatusCode; Version = $h.version; Calls = $h.calls; Max = $h.max }
    } catch [System.Net.WebException] {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        return [pscustomobject]@{ Ok = $false; Status = $status; Version = $null; Calls = $null; Max = $null }
    } catch {
        return [pscustomobject]@{ Ok = $false; Status = 0; Version = $null; Calls = $null; Max = $null }
    }
}

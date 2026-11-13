# ============================================
# whip_voice - check the voice server set-up on this machine
# ============================================
#
# Double-click "Check voice server.bat" (next to this file), or from an ADMINISTRATOR PowerShell:
#
#     powershell -ExecutionPolicy Bypass -File check.ps1
#
# It CHANGES NOTHING. It looks at every piece the voice needs, in the order a player's game uses them, and
# says for each one: OK, or what is wrong and how to fix it.
#
#   LiveKit      the voice server: installed, running, listening, its keys, the address it gives players
#   Caddy        the HTTPS front door: running, holding ports 80 and 443, serving your voice address
#   address      an IP: still this server's; a domain: it points at this server
#   HTTPS        your voice address answers, with a valid certificate, from LiveKit, and when the certificate ends
#   voice bot    (lore characters phoning players) its service running and answering
#   server.cfg   whip_voice's lines, matching LiveKit's keys and the voice bot's token, kept off players' games
#
# What it CANNOT see from inside this machine: whether your HOST's firewall (OVH, Hetzner, AWS...) lets the
# voice ports in. In game, an admin types /voicecheck: it asks every player's game how it connected.
#
# Options:
#   -Domain <address>           the voice address, this server's IP or a domain (default: the one in Caddy's config)
#   -ServerCfg <path>           a server.cfg to check (default: the one above this resources folder; none there, it asks)
#   -SkipCaddy                  you run your own HTTPS proxy instead of Caddy (its part is not checked)
#   -FromInstaller              (used by install.ps1)

param(
    [string]$Domain = '',
    [string]$ServerCfg = '',
    [string]$InstallDir = 'C:\LiveKit',
    [switch]$SkipCaddy,
    [switch]$FromInstaller
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

$problems = New-Object 'System.Collections.Generic.List[string]'
function Problem([string]$what, [string]$fix) { Bad $what; if ($fix) { Fix $fix }; $problems.Add($what) }

if (-not $FromInstaller) {
    Say ''
    Say 'whip_voice: checking the voice server on this machine (nothing is changed)' 'Cyan'
}
$admin = Test-Admin
if (-not $admin) { Warn 'Not running as administrator: LiveKit''s keys cannot be read, so the server.cfg keys are not compared.' }

# --- LiveKit -------------------------------------------------------------------------------------
Step 'The voice server (LiveKit)'
$exe = Join-Path $InstallDir 'livekit-server.exe'
$configPath = Join-Path $InstallDir 'config.yaml'
$lk = $null
if (-not (Test-Path $exe)) {
    Problem "LiveKit is not installed ($exe is missing)" 'double-click "Setup voice server.bat".'
} else {
    Good "installed ($InstallDir)"
    $svc = Get-Service -Name 'LiveKit' -ErrorAction SilentlyContinue
    if (-not $svc) { Problem 'there is no "LiveKit" Windows service' 'double-click "Setup voice server.bat" (it makes the service).' }
    elseif ($svc.Status -ne 'Running') { Problem "the LiveKit service is $($svc.Status)" 'start it: Services > "LiveKit voice server" > Start (or run the setup again).' }
    else {
        Good 'the LiveKit service is running'
        if ($svc.StartType -ne 'Automatic') { Warn "it starts $($svc.StartType), not with Windows"; Fix 'Services > "LiveKit voice server" > Startup type: Automatic.' }
    }
    $answer = $null
    try { $answer = "$((Invoke-WebRequest -Uri 'http://127.0.0.1:7880' -UseBasicParsing -TimeoutSec 4).Content)".Trim() } catch { }
    if ($answer -eq 'OK') { Good 'it answers on 127.0.0.1:7880 (where Caddy and the FiveM server reach it)' }
    else { Problem 'it does not answer on 127.0.0.1:7880' "look at its log: $InstallDir\logs\livekit.log" }
    if (Get-PortOwner 7881 'TCP') { Good 'listening for voice on TCP 7881 (the fallback)' } else { Problem 'nothing listens on TCP 7881' 'restart the LiveKit service; if that does not help, run the setup again.' }
    if (Get-PortOwner 7882 'UDP') { Good 'listening for voice on UDP 7882-7893' } else { Problem 'nothing listens on UDP 7882' 'restart the LiveKit service; if that does not help, run the setup again.' }
    $lk = Read-LiveKitConfig $configPath
    if (-not $lk) { Problem "its config is missing ($configPath)" 'run the setup again.' }
    elseif ($lk.Unreadable) { Warn 'its config is locked to administrators (as it should be): run this as administrator to check the keys.' }
    else {
        if ($lk.Key -and $lk.Secret) { Good 'it has its API key and secret' } else { Problem 'its config has no whip key and secret' 'run the setup again (it keeps or makes a pair).' }
    }
    foreach ($rule in @($script:FwUdp, $script:FwTcp)) {
        $r = Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
        if ($r -and "$($r.Enabled)" -eq 'True') { Good "Windows firewall: $rule" } else { Problem "the Windows firewall rule is missing or off: $rule" 'run the setup again (it adds the rules).' }
    }
}

# --- This server's address -------------------------------------------------------------------------
$nicIp = Get-NicIp
$extIp = Get-ExternalIp
$publicIp = $extIp
if (-not $publicIp) { $publicIp = $nicIp }
if ($lk -and -not $lk.Unreadable -and $lk.NodeIp -and $publicIp -and $lk.NodeIp -ne $publicIp) {
    Problem "LiveKit tells players to send their voice to $($lk.NodeIp), but the internet sees this server as $publicIp" 'run the setup again (it works the address out), or: install.ps1 -PublicIp <the right address>.'
} elseif ($lk -and -not $lk.Unreadable -and $lk.NodeIp) {
    Good "LiveKit gives players this server's public address ($($lk.NodeIp))"
}
if ($nicIp -and (Test-PrivateIp $nicIp) -and $extIp -and $extIp -ne $nicIp) {
    Warn "this machine is behind a router (its own address is $nicIp; the internet sees $extIp)"
    Fix 'forward TCP 80, 443, 7881 and UDP 7882-7893 on the router to this machine.'
}

# --- Caddy ---------------------------------------------------------------------------------------
Step 'The HTTPS front door (Caddy)'
$caddy = Find-Caddy
if ($SkipCaddy) {
    Warn 'not checked: you run your own HTTPS proxy (-SkipCaddy); the HTTPS check below covers it'
} elseif (-not $caddy) {
    Problem 'Caddy is not installed' 'double-click "Setup voice server.bat": it installs Caddy for you. (Using another web server instead? Point its HTTPS for your voice address at 127.0.0.1:7880, with WebSockets on.)'
} else {
    Good "installed ($($caddy.Exe))"
    if ($caddy.Service) {
        $cs = Get-Service -Name $caddy.Service -ErrorAction SilentlyContinue
        if ($cs.Status -eq 'Running') { Good 'the caddy service is running' } else { Problem "the caddy service is $($cs.Status)" 'start it: Services > caddy > Start.' }
    } else {
        Warn 'Caddy is not a Windows service here: it only runs while someone keeps it running'
        Fix 'run the setup again; it makes it a service.'
    }
    foreach ($port in @(443, 80)) {
        $o = Get-PortOwner $port 'TCP'
        if (-not $o) { Problem "nothing listens on TCP $port" 'start the caddy service.' }
        elseif ($o.Name -notmatch '^caddy') { Problem "TCP $port is held by $($o.Name), not Caddy" "stop $($o.Name) (or remove its site on port $port), then restart the caddy service." }
        else { Good "Caddy holds TCP $port" }
    }
    $site = Get-VoiceSite $caddy.Caddyfile
    if (-not $Domain) { $Domain = $site }
    if (-not $site) { Problem "Caddy's config ($($caddy.Caddyfile)) has no site for the voice server" 'run the setup again: it adds your voice address.' }
    elseif ($Domain -and $site -ne $Domain) { Warn "Caddy serves the voice server as $site, not $Domain" }
    else { Good "Caddy serves $site and passes it to LiveKit" }
}

# --- DNS and HTTPS ---------------------------------------------------------------------------------
if ($Domain) {
    Step "Your voice address ($Domain)"
    $isIp = Test-IPv4 $Domain
    if ($isIp) {
        # Players' games connect to the IP itself: it must still be this server's.
        if ($publicIp -and $Domain -ne $publicIp) {
            Problem "the voice address is $Domain, but the internet sees this server as $publicIp" 'run "Setup voice server.bat" again: it moves the voice address to this server''s address and updates server.cfg.'
        } else {
            Good "$Domain is this server's own address (no DNS record needed)"
        }
    } else {
        $ips = @(Resolve-Public $Domain)
        if ($ips.Count -eq 0) {
            Problem "$Domain does not exist on the internet yet" "where you bought your domain, add an A record: name = the part before your domain, value = $publicIp. It can take a few minutes to appear."
        } elseif ($publicIp -and ($ips -notcontains $publicIp)) {
            if (@($ips | Where-Object { Test-CloudflareIp $_ }).Count -gt 0) {
                Problem "$Domain goes through Cloudflare's proxy (orange cloud), which cannot carry the voice server" 'in Cloudflare, click the orange cloud next to the record so it turns grey ("DNS only").'
            } else {
                Problem "$Domain points at $($ips -join ', '), not this server ($publicIp)" "change its A record to $publicIp."
            }
        } else {
            Good "$Domain points at this server"
        }
    }
    $https = Test-Https $Domain
    if ($https.Ok) { Good "https://$Domain answers, with a valid certificate, from LiveKit" }
    elseif ($https.Status -gt 0) { Problem "https://$Domain answered $($https.Status), not LiveKit" 'Caddy''s site for it must say: reverse_proxy 127.0.0.1:7880 (run the setup again to put it right).' }
    elseif ($isIp) {
        Problem "https://$Domain does not answer properly ($($https.Why))" 'usually one of: ports 80 and 443 are closed in your host''s firewall, so Caddy cannot get the certificate; Caddy is stopped; or Caddy is too old for a certificate for an IP address. Caddy''s log says which.'
    } else {
        Problem "https://$Domain does not answer properly ($($https.Why))" 'usually one of: the DNS record is not there yet; ports 80 and 443 are closed in your host''s firewall, so Caddy cannot get a certificate; or Caddy is stopped. Caddy''s log says which.'
    }
    # When the certificate runs out. Caddy renews it by itself well before: for an IP (a certificate of about 6 days)
    # every few days, for a domain about a month ahead. Less than a day left means renewing is failing.
    $cert = Get-HttpsCertificate $Domain
    if ($cert.Ok -and $cert.NotAfter) {
        $left = $cert.NotAfter - (Get-Date)
        $when = $cert.NotAfter.ToString('d MMM yyyy HH:mm')
        if ($left.TotalHours -lt 24) {
            Problem "the certificate runs out in $([math]::Max(0, [math]::Round($left.TotalHours))) hour(s) ($when) and Caddy has not renewed it" 'Caddy''s log says why (usually ports 80 and 443 closed in your host''s firewall). When it runs out, players'' games cannot connect to voice.'
        } else {
            Good "the certificate is valid until $when (Caddy renews it by itself)"
        }
    }
} else {
    Warn 'no voice address to check (Caddy has none yet): skipping DNS and HTTPS'
}

# --- The voice bot ---------------------------------------------------------------------------------
Step 'The voice bot (lore characters phoning players)'
$botDir = Join-Path $InstallDir 'voicebot'
$bot = Read-VoiceBotConfig (Join-Path $botDir 'config.json')
$botSvc = Get-Service -Name 'whip-voicebot' -ErrorAction SilentlyContinue
if (-not $bot -and -not $botSvc) {
    Problem 'the voice bot is not installed: lore characters cannot phone players' 'double-click "Setup voice server.bat": it installs it.'
} else {
    if (-not $botSvc) { Problem 'there is no "whip-voicebot" Windows service' 'double-click "Setup voice server.bat" (it makes the service).' }
    elseif ($botSvc.Status -eq 'Paused') { Problem 'the voice bot service is Paused: it stops as soon as it starts, so Windows gave up on it' "the end of its log says why: $botDir\logs\voicebot.log" }
    elseif ($botSvc.Status -ne 'Running') { Problem "the voice bot service is $($botSvc.Status)" 'start it: the Windows Services window (Windows key, type services.msc) > "whip_voice voice bot" > Start (or run the setup again).' }
    else { Good 'the voice bot service is running' }
    if (-not $bot) { Problem "its config is missing ($botDir\config.json)" 'run the setup again.' }
    elseif ($bot.Unreadable) {
        # Its token is locked to administrators: asked without it, a running bot still answers (refusing).
        $h = Test-VoiceBot ''
        if ($h.Status -eq 401) { Good 'it answers on 127.0.0.1:7899 (run this as administrator to check its token)' }
        else { Problem 'it does not answer on 127.0.0.1:7899' "look at its log: $botDir\logs\voicebot.log" }
    } else {
        $h = Test-VoiceBot $bot.Token
        if ($h.Ok) { Good "it answers on 127.0.0.1:7899 (version $($h.Version), $($h.Calls) of $($h.Max) calls in use)" }
        elseif ($h.Status -eq 401) { Problem 'it refused the token in its own config.json' 'restart the voice bot service (it reads config.json when it starts).' }
        else { Problem 'it does not answer on 127.0.0.1:7899' "look at its log: $botDir\logs\voicebot.log" }
    }
}

# --- server.cfg ------------------------------------------------------------------------------------
if (-not $FromInstaller) {
    if (-not $ServerCfg) { $ServerCfg = Find-ServerCfg $PSScriptRoot }   # the server this whip_voice is in
    if (-not $ServerCfg -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Say ''
        Say 'To check a server.cfg as well, paste its full path here (right-click pastes) and press Enter, or just press Enter to skip:' 'Cyan'
        $ServerCfg = Get-CleanPath (Read-Host ' ')
    }
    if ($ServerCfg) {
        Step "server.cfg ($ServerCfg)"
        if (-not (Test-Path $ServerCfg)) { Problem 'that file does not exist' 'paste the full path of the server.cfg file itself, like C:\FXServer\server-data\server.cfg.' }
        else {
            $cfg = Read-ServerCfgVoice $ServerCfg @(Get-VoiceCategories $PSScriptRoot)
            if ($cfg.Public.Count -gt 0) {
                Problem "$($cfg.Public -join ', ') is set with setr/sets: EVERY PLAYER can read it" 'change those lines to plain "set", restart the server, then run the setup with -NewKeys to make a new secret (the old one has been seen).'
            }
            if (-not $cfg.Url) { Problem 'there is no whip_voice_url line' 'run the setup again and copy the lines it prints into server.cfg.' }
            elseif ($Domain -and $cfg.Url -ne "wss://$Domain") { Problem "whip_voice_url is $($cfg.Url), not wss://$Domain" "set whip_voice_url `"wss://$Domain`"" }
            else { Good "whip_voice_url is $($cfg.Url)" }
            if (-not $cfg.Key -or -not $cfg.Secret) { Problem 'the whip_voice_key or whip_voice_secret line is missing' 'run the setup again and copy the lines it prints into server.cfg.' }
            elseif ($lk -and -not $lk.Unreadable -and $lk.Key) {
                if ($cfg.Key -eq $lk.Key -and $cfg.Secret -eq $lk.Secret) { Good 'the key and secret match LiveKit''s' }
                else { Problem 'the key or secret in server.cfg does not match LiveKit''s config' 'run the setup again and copy the lines it prints into server.cfg (replacing the old ones).' }
            } else { Good 'the key and secret lines are there' }
            if ($bot) {
                if (-not $cfg.BotToken) { Problem 'the voice bot is set up but there is no whip_voicebot_token line' 'run the setup again and copy the whip_voicebot_token line it prints into server.cfg.' }
                elseif ($bot.Token -and $cfg.BotToken -ne $bot.Token) { Problem 'whip_voicebot_token does not match the voice bot''s config.json' 'run the setup again and copy its whip_voicebot_token line into server.cfg (replacing the old one).' }
                else { Good 'the voice bot''s token line is there' }
            }
            if ($cfg.EnsureVoice) { Good 'whip_voice is started (ensure whip_voice, or the folder it is in)' } else { Problem 'nothing in it starts whip_voice' 'add "ensure whip_voice" after "ensure whip_core".' }
            if ($cfg.Mumble) {
                Warn 'sv_mumble is on: whip_voice does not use it, and on, any player''s game can listen to any Mumble channel'
                Fix 'put # in front of the sv_mumble line.'
            }
        }
    }
}

# --- The answer ------------------------------------------------------------------------------------
Say ''
if ($problems.Count -eq 0) {
    Say 'Everything checked is right.' 'Green'
    Say 'Still to check from outside: in game, as an admin, type /voicecheck (it asks every player''s game how it connected).'
} else {
    Say "$($problems.Count) thing(s) to fix, top to bottom (an early one often causes the later ones):" 'Yellow'
    $i = 0
    foreach ($p in $problems) { $i++; Say "  $i. $p" 'Yellow' }
}
if ($FromInstaller) { return $problems.Count }
exit $problems.Count

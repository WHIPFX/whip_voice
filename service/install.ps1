# ============================================
# whip_voice - the voice server set-up wizard (LiveKit, and Caddy for HTTPS)
# ============================================
#
# THE EASY WAY: double-click "Setup voice server.bat" next to this file. It asks Windows for administrator
# rights and runs this, start to finish, with nothing to answer. The whole guide: whip_voice\docs\SETUP.md.
#
# Or from an ADMINISTRATOR PowerShell, on the machine that runs your FiveM server:
#
#     powershell -ExecutionPolicy Bypass -File install.ps1
#
# What it does, step by step (safe to run again: it keeps your keys, and a step already done is skipped):
#   First, NSSM, which runs the services below: downloaded (checked) unless this machine has the same file already
#   1. works out this server's public address: the voice address players' games connect to (no domain needed).
#      With -Domain, a domain name instead; a re-run keeps the address set up last time
#   2. a domain only: shows you the DNS record to add, and waits until the internet can see it
#   3. reminds you to open the voice ports in your HOST's firewall (OVH, Hetzner, AWS...), if it has one
#   4. Caddy, the HTTPS front door: installs it if this machine has none (checked download), or adds your
#      voice address to the one you have. For an IP address it asks Let's Encrypt for an IP certificate (about 6
#      days long; Caddy renews it by itself)
#   5. LiveKit, the voice server: downloads it (checked) unless this version is already installed, makes its
#      config with random keys, makes it a Windows service, opens its ports in the Windows firewall
#   6. the voice bot (lore characters phoning players with a recorded line): its own Node.js (checked download)
#      and the bot in C:\LiveKit\voicebot, a Windows service on 127.0.0.1 only, a random token
#   (What is already installed and the same is left alone, and a running service is only restarted for a change.)
#   7. waits for the certificate, then checks everything (check.ps1)
#   8. writes the lines into the server.cfg of the FiveM server this whip_voice is in (the folder above "resources"),
#      with a backup; found none, it prints them (and puts them on the clipboard). Two servers on this machine (Legacy
#      and FiveM for GTAV Enhanced) share the voice server: run it from each one's whip_voice and both get the same lines
#
# Options (all optional):
#   -Domain voice.example.com   a domain name as the voice address, instead of this server's IP (you add its DNS record)
#   -UseIp                      back to this server's IP as the voice address, after a domain was set up
#   -PublicIp 1.2.3.4           this server's public IPv4 (default: worked out)
#   -ServerCfg "<path>;<path>"  write the lines into these server.cfg files (with a backup of each) instead of the one
#                               above this resources folder
#   -SkipCaddy                  you run your own HTTPS proxy; point it at 127.0.0.1:7880 (WebSockets on)
#   -NewKeys                    make a new key, secret and voice bot token (after the old secret was seen somewhere)
#   -Yes                        ask nothing: use the options and the defaults (for scripts)
#   -Uninstall                  removes the LiveKit and voice bot services and the firewall rules (keeps C:\LiveKit
#                               and Caddy)

param(
    [string]$Domain = '',
    [string]$PublicIp = '',
    [string]$InstallDir = 'C:\LiveKit',
    [string]$CaddyDir = 'C:\Caddy',
    [string[]]$ServerCfg = @(),
    [switch]$UseIp,
    [switch]$SkipCaddy,
    [switch]$NewKeys,
    [switch]$Yes,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# --- Pinned downloads (change each version, address and checksum together when upgrading) -----------
$Version = '1.13.7'
$ZipUrl  = "https://github.com/livekit/livekit/releases/download/v$Version/livekit_$($Version)_windows_amd64.zip"
$ZipSha  = 'e539e7d2f75807b9c9202cd2a0bf2cb3d52fc4c52978a6953e0f47bc339fe77f'   # SHA-256, from the release's checksums.txt

$CaddyVersion = '2.11.7'
$CaddyZipUrl  = "https://github.com/caddyserver/caddy/releases/download/v$CaddyVersion/caddy_$($CaddyVersion)_windows_amd64.zip"
$CaddyZipSha  = 'c308154504e53755958ffc62d8a2657ab17eefd6dd25c45dbb2c3d93d29519971f77ca652f7d0f2bcb7f980b9ba3822478865e29969d0272d7613550a43152b1'   # SHA-512, from caddy_2.11.7_checksums.txt

$NodeVersion = '22.19.0'
$NodeZipUrl  = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-x64.zip"
$NodeZipSha  = 'ea3fad0e67a991d8477d8c01344b56e69c676ccb733f065b22436994b1253f86'   # SHA-256, from the release's SHASUMS256.txt

# nssm.cc publishes only a SHA-1 for this zip (be7b3577c6e3a280e5106a9e9db5b3775931cefc, on nssm.cc/download). The
# SHA-256 below is of the file with that SHA-1, and Chocolatey's nssm 2.24 package publishes the same one.
$NssmVersion = '2.24'
$NssmZipUrl  = "https://nssm.cc/release/nssm-$NssmVersion.zip"
$NssmZipSha  = '727d1e42275c605e0f04aba98095c38a8e1e46def453cdffce42869428aa6743'   # SHA-256 of the zip
# (Its nssm.exe's own SHA-256 is $NssmExeSha in common.ps1, which checks a copy already on this machine.)

$ServiceName = 'LiveKit'
$Exe         = Join-Path $InstallDir 'livekit-server.exe'
$Config      = Join-Path $InstallDir 'config.yaml'
$LogDir      = Join-Path $InstallDir 'logs'
$Template    = Join-Path $PSScriptRoot 'config.yaml.example'

$BotService  = 'whip-voicebot'
$BotDir      = Join-Path $InstallDir 'voicebot'
$BotApp      = Join-Path $BotDir 'app'                                   # the bot itself (replaced on every run)
$BotNode     = Join-Path $BotDir "node-v$NodeVersion-win-x64"            # its own Node.js
$BotConfig   = Join-Path $BotDir 'config.json'                           # kept on every run: the token, the sites
$BotLogDir   = Join-Path $BotDir 'logs'
$BotSource   = Join-Path $PSScriptRoot 'voicebot'

$Interactive = (-not $Yes) -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

# --- Asking ---------------------------------------------------------------------------------------
function PressEnter([string]$text) {
    if (-not $Interactive) { return }
    [void](Read-Host "  $text")
}

# --- Administrator? ------------------------------------------------------------------------------
if (-not (Test-Admin)) {
    throw 'Run this as administrator: double-click "Setup voice server.bat", or right-click PowerShell > Run as administrator.'
}

# --- NSSM (runs a program as a Windows service) ---------------------------------------------------
# It runs as administrator here, so it is checked like every download. A copy already on this machine is checked as
# well (Find-Nssm): older versions of this wizard downloaded it without a check.
$Nssm = Find-Nssm $InstallDir
if (-not $Nssm) {
    Say "Downloading NSSM $NssmVersion (it runs the voice server as a Windows service)..." 'Yellow'
    $dir = Join-Path $InstallDir 'tools\nssm'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $zip = Join-Path $env:TEMP "nssm-$NssmVersion.zip"
    Invoke-WebRequest -Uri $NssmZipUrl -OutFile $zip -UseBasicParsing
    $hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $NssmZipSha) {
        Remove-Item $zip -Force
        throw "The NSSM download does not match its checksum (got $hash). Nothing was installed."
    }
    Good 'the download matches the official release'
    # A copy Find-Nssm turned down may be the very program services are running (an older wizard made them from it),
    # and Windows refuses to overwrite a running program: those services stop for the unpack and start again after,
    # now on the checked copy.
    $target = Join-Path $dir "nssm-$NssmVersion\win64\nssm.exe"
    $holding = @()
    if (Test-Path $target) {
        $holding = @(Get-CimInstance Win32_Service | Where-Object {
            $_.State -eq 'Running' -and $_.PathName -and
            $_.PathName.IndexOf($target, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        foreach ($s in $holding) {
            Say "  stopping $($s.Name) while NSSM is replaced" 'Gray'
            Stop-Service -Name $s.Name -Force -ErrorAction Stop
        }
    }
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    Remove-Item $zip -Force
    foreach ($s in $holding) { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
    $Nssm = $target
}
# NSSM writes harmless messages to stderr (e.g. "service not running"); run those through cmd so
# PowerShell 5.1 does not treat them as errors.
function Nssm-Quiet($argsText) { & cmd.exe /c "`"$Nssm`" $argsText > nul 2>&1" }

function Remove-Service-IfPresent([string]$name) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne 'Stopped') { Nssm-Quiet "stop $name confirm"; Start-Sleep -Seconds 2 }
        Nssm-Quiet "remove $name confirm"
        Start-Sleep -Seconds 1
    }
}

# --- Uninstall -----------------------------------------------------------------------------------
if ($Uninstall) {
    Step 'Removing the LiveKit and voice bot services and their firewall rules'
    Remove-Service-IfPresent $BotService
    Remove-Service-IfPresent $ServiceName
    Get-NetFirewallRule -DisplayName $script:FwUdp -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallRule -DisplayName $script:FwTcp -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Say "Done. $InstallDir and Caddy were left alone; delete them by hand if you want." 'Green'
    return
}

Say ''
Say '  whip_voice: setting up the voice server' 'Cyan'
Say '  ----------------------------------------'
Say '  It runs start to finish by itself, with nothing to answer. All it needs is this machine: a Windows server you'
Say '  control (you are on it now). No domain name: players'' games connect to this server''s own address.'
Say '  Press Ctrl+C to stop at any time. Stopped part-way? Just run it again: it carries on from where it got to.'

# --- 1. This server's address, and the voice address -------------------------------------------------
Step '1. The voice address'
if (-not $PublicIp) {
    $nic = Get-NicIp
    $ext = Get-ExternalIp
    if ($ext) { $PublicIp = $ext } else { $PublicIp = $nic }
    if ($nic -and $ext -and $nic -ne $ext -and (Test-PrivateIp $nic)) {
        Warn "this machine is behind a router: its own address is $nic, the internet sees $ext"
        Say '         On the router, forward TCP 80, 443, 7881 and UDP 7882-7893 to this machine.' 'Gray'
    }
}
if (-not ($PublicIp -match '^\d{1,3}(\.\d{1,3}){3}$')) {
    throw 'Could not work out this server''s public IPv4. Run again with -PublicIp <your IP>.'
}
Good "this server's public address: $PublicIp"

# The voice address: -Domain when given; else a domain set up by a run before; else this server's own IP (an IP set up
# before follows the server when its address changes).
$caddy = $null
if (-not $SkipCaddy) { $caddy = Find-Caddy $CaddyDir }
$previous = $null
if ($caddy) { $previous = Get-VoiceSite $caddy.Caddyfile }
if ($Domain) {
    $Address = Get-CleanAddress $Domain
    if (-not $Address) { throw 'That -Domain is not a domain name (like voice.example.com) or an IP address.' }
} elseif ($UseIp -or -not $previous -or (Test-IPv4 $previous)) {
    $Address = $PublicIp
    if ($previous -and $previous -ne $Address) { Warn "the voice address was $($previous): it is now this server's address, $Address" }
} else {
    $Address = $previous
}
$IsIp = Test-IPv4 $Address
if ($IsIp) {
    if (Test-PrivateIp $Address) { throw "$Address is a private address: players' games cannot reach it. Run again with -PublicIp <this server's public IP>." }
    if ($Address -ne $PublicIp) { Warn "$Address is not this server's public address ($PublicIp)" }
    Good "voice address: $Address (this server's own address: players' games connect to it directly)"
    Say '         A domain name instead (voice.myserver.com)? Run: Setup voice server.bat -Domain voice.myserver.com' 'Gray'
} else {
    Good "voice address: $Address"
}

# --- 2. DNS ---------------------------------------------------------------------------------------
Step '2. The DNS record'
if ($IsIp) {
    Good 'none needed: the voice address is this server''s own IP'
} else {
    $labels = $Address.Split('.')
    $hostPart = if ($labels.Count -gt 2) { ($labels[0..($labels.Count - 3)]) -join '.' } else { '@' }
    $ips = @(Resolve-Public $Address)
    if ($ips -contains $PublicIp) {
        Good "$Address already points at this server"
    } else {
        Say '  Where you bought your domain (GoDaddy, Namecheap, Cloudflare, ...), open its DNS settings and add:'
        Say ''
        Say "      Type:   A" 'White'
        Say "      Name:   $hostPart" 'White'
        Say "      Value:  $PublicIp" 'White'
        Say '      TTL:    leave it as it is (Auto)' 'White'
        Say ''
        Say '  On Cloudflare: make it "DNS only" (a grey cloud, not orange). Its proxy cannot carry voice.'
        if ($ips.Count -gt 0) {
            if (@($ips | Where-Object { Test-CloudflareIp $_ }).Count -gt 0) { Warn "$Address goes through Cloudflare's proxy now: turn the cloud grey" }
            else { Warn "$Address points at $($ips -join ', ') now: change it to $PublicIp" }
        }
        if ($Interactive) {
            Say ''
            Say "  Waiting for $Address to point here (checked every 15 seconds; usually a few minutes)." 'Cyan'
            Say '  Press any key to stop waiting and carry on anyway.'
            $deadline = (Get-Date).AddMinutes(60)
            $ready = $false
            while (-not $ready -and (Get-Date) -lt $deadline) {
                $stop = $false
                for ($i = 0; $i -lt 30 -and -not $stop; $i++) {
                    Start-Sleep -Milliseconds 500
                    if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); $stop = $true }
                }
                if ($stop) { break }
                $ips = @(Resolve-Public $Address)
                if ($ips -contains $PublicIp) { $ready = $true }
                elseif ($ips.Count -gt 0) { Say "  ...it points at $($ips -join ', ') so far" 'Yellow' }
                else { Say '  ...not there yet' }
            }
            if ($ready) { Good "$Address points at this server" }
            else { Warn 'carrying on without it: the certificate comes once the record is there (run "Check voice server.bat" later)' }
        } else {
            Warn "$Address does not point here yet: add the record ($hostPart -> $PublicIp); the certificate comes once it does"
        }
    }
}

# --- 3. The host's firewall --------------------------------------------------------------------------
Step '3. Your host''s firewall'
Say '  This wizard opens the ports in WINDOWS'' firewall itself. Many hosts also have a firewall of their own,'
Say '  in their website''s control panel (OVH, Hetzner, AWS, Azure, Google Cloud, ...). If yours does, allow'
Say '  these INBOUND there:'
Say ''
Say '      TCP 80 and 443        the secure address (and getting its certificate)' 'White'
Say '      TCP 7881              voice (the fallback)' 'White'
Say '      UDP 7882 to 7893      voice' 'White'
Say ''
# An IP address runs straight on: the check at the end says if a port is still shut, and Caddy keeps asking for the
# certificate until it gets through. A domain already waited for its DNS record, so this waits as well.
if ($IsIp) { Say '  Not done yet? Carry on anyway: the check at the end tells you, and the certificate comes once they are open.' 'Gray' }
else { PressEnter 'Press Enter when that is done (or if your host has no such firewall)' }

# --- 4. Caddy --------------------------------------------------------------------------------------
function Run-Caddy([string]$exe, [string[]]$arguments) {
    # Caddy prints its normal progress notes on stderr. PowerShell 5.1 with ErrorActionPreference 'Stop'
    # turns ANY stderr line into a fatal error, so Caddy runs with the preference relaxed and is judged by
    # its exit code alone.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = (& $exe @arguments 2>&1 | ForEach-Object { "$_" }) -join "`n" }
    finally { $ErrorActionPreference = $old }
    return @{ Code = $LASTEXITCODE; Out = $out }
}

function Install-Caddy {
    # A "caddy" service this could not read (not NSSM's, no caddy.exe in its command line) is somebody's own:
    # never replaced.
    if (Get-Service -Name 'caddy' -ErrorAction SilentlyContinue) {
        throw 'There is a "caddy" Windows service already, but its caddy.exe could not be found. Fix or remove that service, or run this again with -SkipCaddy and point your web server at 127.0.0.1:7880.'
    }
    foreach ($port in @(80, 443)) {
        $o = Get-PortOwner $port 'TCP'
        if ($o) {
            Bad "TCP $port is already used by $($o.Name) $($o.Path)"
            Say '         Caddy needs ports 80 and 443. Either stop that program (and stop it starting with Windows),' 'Gray'
            Say '         or keep it and run this again with -SkipCaddy, then point its HTTPS for your voice address' 'Gray'
            Say '         at 127.0.0.1:7880 with WebSockets on.' 'Gray'
            throw "Port $port is in use, so Caddy cannot be installed."
        }
    }
    Say "  Downloading Caddy $CaddyVersion (a web server that gets and renews a free HTTPS certificate by itself)..."
    New-Item -ItemType Directory -Path $CaddyDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $CaddyDir 'logs') -Force | Out-Null
    $zip = Join-Path $env:TEMP "caddy_$($CaddyVersion)_windows_amd64.zip"
    Invoke-WebRequest -Uri $CaddyZipUrl -OutFile $zip -UseBasicParsing
    $hash = (Get-FileHash -Path $zip -Algorithm SHA512).Hash.ToLower()
    if ($hash -ne $CaddyZipSha) {
        Remove-Item $zip -Force
        throw 'The Caddy download does not match its published checksum. Nothing was installed.'
    }
    Good 'the download matches the official release'
    $unz = Join-Path $env:TEMP "caddy_$CaddyVersion"
    if (Test-Path $unz) { Remove-Item $unz -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $unz -Force
    $exe = Join-Path $CaddyDir 'caddy.exe'
    Copy-Item (Join-Path $unz 'caddy.exe') $exe -Force
    Copy-Item (Join-Path $unz 'LICENSE') (Join-Path $CaddyDir 'LICENSE') -Force
    Remove-Item $unz -Recurse -Force
    Remove-Item $zip -Force

    $cf = Join-Path $CaddyDir 'Caddyfile'
    if (-not (Test-Path $cf)) {
        $head = "# Caddy: the HTTPS front door of this server. Made by whip_voice\service\install.ps1.`r`n" +
                "# Each site below gets its own free certificate, renewed by Caddy itself. After a change: restart the caddy service.`r`n"
        [IO.File]::WriteAllText($cf, $head, (New-Object Text.UTF8Encoding($false)))
    }
    & icacls $CaddyDir /grant 'NT AUTHORITY\LocalService:(OI)(CI)RX' | Out-Null
    & icacls (Join-Path $CaddyDir 'logs') /grant 'NT AUTHORITY\LocalService:(OI)(CI)M' | Out-Null
    [IO.File]::WriteAllText((Join-Path $CaddyDir 'installed-by-whip_voice.txt'),
        "Caddy $CaddyVersion was installed here by whip_voice\service\install.ps1 on $(Get-Date -Format 'yyyy-MM-dd').`r`n")

    Remove-Service-IfPresent 'caddy'
    & $Nssm install caddy $exe 'run' '--config' $cf '--adapter' 'caddyfile' | Out-Null
    & $Nssm set caddy DisplayName 'Caddy web server (HTTPS for whip_voice)' | Out-Null
    & $Nssm set caddy Description "The secure address players' games reach the voice server through. Config: $cf" | Out-Null
    & $Nssm set caddy AppDirectory $CaddyDir | Out-Null
    & $Nssm set caddy Start SERVICE_AUTO_START | Out-Null
    & $Nssm set caddy ObjectName 'NT AUTHORITY\LocalService' | Out-Null
    & $Nssm set caddy AppStdout (Join-Path $CaddyDir 'logs\caddy.log') | Out-Null
    & $Nssm set caddy AppStderr (Join-Path $CaddyDir 'logs\caddy.log') | Out-Null
    & $Nssm set caddy AppRotateFiles 1 | Out-Null
    & $Nssm set caddy AppRotateOnline 1 | Out-Null
    & $Nssm set caddy AppRotateSeconds 86400 | Out-Null
    & $Nssm set caddy AppRotateBytes 52428800 | Out-Null
    & $Nssm set caddy AppExit Default Restart | Out-Null
    & $Nssm set caddy AppRestartDelay 3000 | Out-Null

    Get-NetFirewallRule -DisplayName $script:FwCaddy -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallRule -DisplayName $script:FwCaddyUdp -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $script:FwCaddy -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Program $exe | Out-Null
    New-NetFirewallRule -DisplayName $script:FwCaddyUdp -Direction Inbound -Action Allow -Protocol UDP -LocalPort 443 -Program $exe | Out-Null
    Good 'Caddy installed as the "caddy" Windows service; TCP 80, 443 (and UDP 443) open in the Windows firewall for it'
    return [pscustomobject]@{ Exe = $exe; Caddyfile = $cf; Service = 'caddy'; Dir = $CaddyDir; New = $true }
}

function Add-CaddySite($c) {
    $current = ''
    if (Test-Path $c.Caddyfile) { $current = [IO.File]::ReadAllText($c.Caddyfile) }
    $backup = $null
    $want = New-VoiceSiteBlock $Address
    # The wizard's own voice site out (one from a run before: another address, or older settings), to see what is left.
    $rest = Remove-VoiceSiteBlock $current
    if ($rest.Text -match ('(?m)^\s*' + [regex]::Escape($Address) + '\s*\{')) {
        # A site for this address that the wizard did not write: somebody's own, left as it is.
        Good "Caddy already has a site for $Address (your own: left as it is)"
        if ($IsIp) { Warn "it needs a certificate for the IP itself: in its tls block, issuer acme with profile shortlived" }
    } elseif ($current.Replace("`r`n", "`n").Contains($want.Replace("`r`n", "`n"))) {
        Good "Caddy already has a site for $Address"
    } else {
        if ($current) {
            $backup = "$($c.Caddyfile).bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item $c.Caddyfile $backup
        }
        $before = ''
        if ($rest.Removed) { $before = $rest.Text.TrimEnd() } else { $before = $current.TrimEnd() }
        $text = $want
        if ($before) { $text = $before + "`r`n`r`n" + $want }
        [IO.File]::WriteAllText($c.Caddyfile, $text, (New-Object Text.UTF8Encoding($false)))
        $what = "added $Address to Caddy"
        if ($rest.Removed) { $what = "Caddy's voice site is now $Address" }
        if ($backup) { Good "$what (the old config is kept as $backup)" } else { Good $what }
    }
    # A syntax check that touches nothing ("validate" would also open Caddy's log files).
    $adapt = Run-Caddy $c.Exe @('adapt', '--config', $c.Caddyfile, '--adapter', 'caddyfile')
    if ($adapt.Code -ne 0) {
        if ($backup) { Copy-Item $backup $c.Caddyfile -Force }
        Say $adapt.Out 'Red'
        throw 'Caddy could not read its config' + $(if ($backup) { ', so it was put back as it was' } else { '' }) + '.'
    }
}

if ($SkipCaddy) {
    Step '4. HTTPS (your own web server: -SkipCaddy)'
    Say "  Point your web server's HTTPS for $Address at 127.0.0.1:7880, with WebSockets on."
    if ($IsIp) { Say '  It needs a certificate for the IP address itself: Let''s Encrypt issues those (its "shortlived" profile).' }
} else {
    Step '4. The HTTPS front door (Caddy)'
    if ($caddy) {
        Good "Caddy is already on this machine ($($caddy.Exe))"
        # A certificate for an IP address needs a recent Caddy. An older one is not replaced (it may serve other sites
        # here): the check below says whether the certificate came.
        if ($IsIp) {
            $v = Run-Caddy $caddy.Exe @('version')
            if ("$($v.Out)" -match 'v(\d+\.\d+\.\d+)' -and [version]$matches[1] -lt [version]$CaddyVersion) {
                Warn "this Caddy is $($matches[1]); certificates for an IP address are known to work from $CaddyVersion"
                Fix "if the check below finds no certificate, update Caddy to $CaddyVersion or newer (caddyserver.com), then run this again."
            }
        }
        Add-CaddySite $caddy
        $reload = Run-Caddy $caddy.Exe @('reload', '--config', $caddy.Caddyfile, '--adapter', 'caddyfile')
        if ($reload.Code -eq 0) { Good "Caddy reloaded: it serves $Address now" }
        elseif ($caddy.Service) {
            try {
                Restart-Service -Name $caddy.Service -ErrorAction Stop
                Good "Caddy restarted: it serves $Address now"
            } catch {
                Bad "Caddy did not restart: $($_.Exception.Message)"
                Say "         Look at Caddy's log, then start the ""$($caddy.Service)"" service (Services, or services.msc)." 'Gray'
            }
        } else {
            Warn 'Caddy is not running as a service here and did not reload: start it with its config to serve the new site'
        }
    } else {
        Say '  This machine has no Caddy: installing it.'
        $caddy = Install-Caddy
        Add-CaddySite $caddy
        Nssm-Quiet 'start caddy'
        Good 'the caddy service is running'
    }
}

# --- 5. LiveKit ------------------------------------------------------------------------------------
Step "5. The voice server (LiveKit $Version)"
$holder = Get-PortOwner 7880 'TCP'
if ($holder -and $holder.Path -and $holder.Path -ne $Exe) {
    throw "Port 7880 is already used by $($holder.Name) ($($holder.Path)). Stop it and run this again."
}
if (-not (Test-Path $Template)) { throw "config.yaml.example not found next to this script ($Template)." }
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# Already installed at this version: nothing to download, and the running service is left alone unless its config
# changes below. Another version, or none: downloaded, checked, put in place.
$lkChanged = $false   # the running service must restart to take it
$have = Get-LiveKitVersion $Exe
if ($have -eq $Version) {
    Good "LiveKit $Version is already installed: nothing to download"
} else {
    if ($have) { Say "  Upgrading LiveKit $have to $Version..." } else { Say "  Downloading LiveKit $Version..." }
    $zip = Join-Path $env:TEMP "livekit_$($Version)_windows_amd64.zip"
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
    $hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $ZipSha) {
        Remove-Item $zip -Force
        throw "The download does not match LiveKit's published checksum (got $hash). Nothing was installed."
    }
    Good 'the download matches the official release'
    # The running service holds the exe, so it is stopped and removed before the file is replaced.
    Remove-Service-IfPresent $ServiceName
    $unz = Join-Path $env:TEMP "livekit_$Version"
    if (Test-Path $unz) { Remove-Item $unz -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $unz -Force
    Copy-Item (Join-Path $unz 'livekit-server.exe') $Exe -Force
    Copy-Item (Join-Path $unz 'LICENSE') (Join-Path $InstallDir 'LICENSE') -Force
    Remove-Item $unz -Recurse -Force
    Remove-Item $zip -Force
    $lkChanged = $true
}

# Keys: keep the existing pair on a re-run (unless -NewKeys), or make a new random one.
function Random-Text([int]$length, [string]$alphabet) {
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] $length
    $rng.GetBytes($bytes)
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}
$ApiKey = $null; $ApiSecret = $null
$old = Read-LiveKitConfig $Config
if ($old -and -not $old.Unreadable -and $old.Key -and -not $NewKeys) {
    $ApiKey, $ApiSecret = $old.Key, $old.Secret
    Good 'keeping your existing API key and secret'
}
if (-not $ApiKey) {
    $ApiKey    = 'whip' + (Random-Text 12 'abcdef0123456789')
    $ApiSecret = Random-Text 48 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    if ($NewKeys) { Good 'made a NEW key and secret (-NewKeys): server.cfg needs the new lines below' } else { Good 'made a new random key and secret' }
}

# config.yaml (UTF-8 without a BOM), readable only by Administrators and the service. Written only when it changes.
$text = [IO.File]::ReadAllText($Template)
$text = $text.Replace('__PUBLIC_IP__', $PublicIp).Replace('__API_KEY__', $ApiKey).Replace('__API_SECRET__', $ApiSecret)
$current = $null
if (Test-Path $Config) { try { $current = [IO.File]::ReadAllText($Config) } catch { } }
if ($current -ceq $text) {
    Good "$Config is up to date"
} else {
    [IO.File]::WriteAllText($Config, $text, (New-Object Text.UTF8Encoding($false)))
    Good "wrote $Config (locked to administrators and the service)"
    $lkChanged = $true
}
& icacls $Config /inheritance:r /grant:r 'BUILTIN\Administrators:F' 'NT AUTHORITY\SYSTEM:F' 'NT AUTHORITY\LocalService:R' | Out-Null
& icacls $InstallDir /grant 'NT AUTHORITY\LocalService:(OI)(CI)RX' | Out-Null
& icacls $LogDir /grant 'NT AUTHORITY\LocalService:(OI)(CI)M' | Out-Null

# The service: made when missing; its settings applied either way (they take effect at its next start).
$lkService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $lkService) { & $Nssm install $ServiceName $Exe '--config' $Config | Out-Null; $lkChanged = $true }
& $Nssm set $ServiceName DisplayName 'LiveKit voice server (whip_voice)' | Out-Null
& $Nssm set $ServiceName Description "Voice relay for the whip_voice FiveM resource. Config: $Config" | Out-Null
& $Nssm set $ServiceName AppDirectory $InstallDir | Out-Null
& $Nssm set $ServiceName Start SERVICE_AUTO_START | Out-Null
& $Nssm set $ServiceName ObjectName 'NT AUTHORITY\LocalService' | Out-Null
& $Nssm set $ServiceName AppStdout (Join-Path $LogDir 'livekit.log') | Out-Null
& $Nssm set $ServiceName AppStderr (Join-Path $LogDir 'livekit.log') | Out-Null
& $Nssm set $ServiceName AppRotateFiles 1 | Out-Null
& $Nssm set $ServiceName AppRotateOnline 1 | Out-Null
& $Nssm set $ServiceName AppRotateSeconds 86400 | Out-Null
& $Nssm set $ServiceName AppRotateBytes 52428800 | Out-Null
& $Nssm set $ServiceName AppExit Default Restart | Out-Null
& $Nssm set $ServiceName AppRestartDelay 3000 | Out-Null

# Firewall: only these ports, only for livekit-server.exe.
Get-NetFirewallRule -DisplayName $script:FwUdp -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName $script:FwTcp -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $script:FwUdp -Direction Inbound -Action Allow -Protocol UDP -LocalPort '7882-7893' -Program $Exe | Out-Null
New-NetFirewallRule -DisplayName $script:FwTcp -Direction Inbound -Action Allow -Protocol TCP -LocalPort 7881 -Program $Exe | Out-Null
Good 'UDP 7882-7893 and TCP 7881 open in the Windows firewall (port 7880 stays closed: Caddy reaches it on this machine)'

# Started, restarted only for a change (a restart drops everyone's voice for a few seconds), or left running.
$lkService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($lkService.Status -eq 'Running' -and -not $lkChanged) {
    Good 'LiveKit was already running with this setup: left running'
} elseif ($lkService.Status -eq 'Running') {
    Nssm-Quiet "restart $ServiceName"
} else {
    & $Nssm start $ServiceName | Out-Null
}
$ok = $false
for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
    Start-Sleep -Milliseconds 500
    try { $ok = ((Invoke-WebRequest -Uri 'http://127.0.0.1:7880' -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) } catch { }
}
if ($ok) { Good 'LiveKit is running' } else { Bad "LiveKit did not answer on 127.0.0.1:7880. Look in $LogDir\livekit.log." }

# --- 6. The voice bot ------------------------------------------------------------------------------
# One small service for every lore character's call (whip_voice\service\voicebot\bot.mjs): it joins the voice
# room and plays a recorded line into a call. Its own Node.js, so nothing else on this machine matters. It listens
# on 127.0.0.1 only: the FiveM server drives it with a token (whip_voicebot_token) and signs each call's pass itself.

#--- A program run with its stderr notes allowed (npm prints warnings there), judged by its exit code alone.
function Run-Tool([string]$exe, [string[]]$arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = (& $exe @arguments 2>&1 | ForEach-Object { "$_" }) -join "`n" }
    finally { $ErrorActionPreference = $old }
    return @{ Code = $LASTEXITCODE; Out = $out }
}

#--- The bot's files, as paths inside whip_voice\service\voicebot: bot.mjs, its package files, and its agent folder.
function VoiceBot-Files {
    $files = @('bot.mjs', 'package.json', 'package-lock.json')
    $agent = Join-Path $BotSource 'agent'
    if (Test-Path $agent) {
        $files += @(Get-ChildItem $agent -Recurse -File | ForEach-Object { $_.FullName.Substring($BotSource.Length).TrimStart('\') })
    }
    return $files
}

#--- Install or upgrade it. Answers its token (for server.cfg), or $null when it could not be set up.
function Install-VoiceBot {
    foreach ($f in @('bot.mjs', 'package.json', 'package-lock.json', 'agent\index.mjs')) {
        if (-not (Test-Path (Join-Path $BotSource $f))) { Bad "whip_voice\service\voicebot\$f is missing: download whip_voice again"; return $null }
    }
    $botFiles = VoiceBot-Files
    $holder = Get-PortOwner 7899 'TCP'
    $ours = Join-Path $BotNode 'node.exe'
    if ($holder -and $holder.Path -and $holder.Path -ne $ours) {
        Bad "port 7899 is already used by $($holder.Name) ($($holder.Path)): the voice bot needs it"
        Fix 'stop that program and run this again.'
        return $null
    }
    New-Item -ItemType Directory -Path $BotDir -Force | Out-Null
    New-Item -ItemType Directory -Path $BotLogDir -Force | Out-Null

    # What is already here and the same is left alone: Node.js, the bot (its files against whip_voice's copy), its
    # config. Only a change stops the running bot (it holds node.exe and its packages) and starts it again.
    $changed = $false
    $needNode = -not (Test-Path $ours)
    $needApp = -not (Test-Path (Join-Path $BotApp 'node_modules'))
    foreach ($f in $botFiles) {
        $dst = Join-Path $BotApp $f
        if (-not (Test-Path $dst) -or (Get-FileHash (Join-Path $BotSource $f)).Hash -ne (Get-FileHash $dst).Hash) { $needApp = $true }
    }
    $svc = Get-Service -Name $BotService -ErrorAction SilentlyContinue
    if (($needNode -or $needApp) -and $svc -and $svc.Status -ne 'Stopped') {
        Nssm-Quiet "stop $BotService"
        Start-Sleep -Seconds 2
    }

    if (-not $needNode) {
        Good "Node.js $NodeVersion is already there"
    } else {
        Say "  Downloading Node.js $NodeVersion (for the voice bot only; nothing else on this machine uses it)..."
        $zip = Join-Path $env:TEMP "node-v$NodeVersion-win-x64.zip"
        Invoke-WebRequest -Uri $NodeZipUrl -OutFile $zip -UseBasicParsing
        $hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $NodeZipSha) {
            Remove-Item $zip -Force
            Bad 'the Node.js download does not match its published checksum: nothing was installed'
            return $null
        }
        Good 'the download matches the official release'
        Expand-Archive -Path $zip -DestinationPath $BotDir -Force
        Remove-Item $zip -Force
    }

    # The bot: replaced only when whip_voice's copy differs; its packages exactly as package-lock.json pins them, no
    # install scripts run.
    if (-not $needApp) {
        Good 'the voice bot is up to date'
    } else {
        if (Test-Path $BotApp) { Remove-Item $BotApp -Recurse -Force }
        New-Item -ItemType Directory -Path $BotApp -Force | Out-Null
        foreach ($f in $botFiles) {
            $dst = Join-Path $BotApp $f
            New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
            Copy-Item (Join-Path $BotSource $f) $dst -Force
        }
        Say '  Installing its packages (LiveKit''s own SDK and the audio decoders)...'
        $oldPath = $env:Path
        $env:Path = "$BotNode;$env:Path"
        Push-Location $BotApp
        try { $npm = Run-Tool (Join-Path $BotNode 'npm.cmd') @('ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund') }
        finally { Pop-Location; $env:Path = $oldPath }
        if ($npm.Code -ne 0) {
            Say $npm.Out 'Red'
            Bad 'its packages could not be installed (above: why). This machine needs to reach registry.npmjs.org.'
            return $null
        }
        Good 'the voice bot is installed, with its packages'
        $changed = $true
    }

    # config.json: kept on a re-run (the token, and any sites or limits you changed), else made with a new token.
    $old = Read-VoiceBotConfig $BotConfig
    $data = [ordered]@{ listen = '127.0.0.1:7899'; token = ''; maxCalls = 30; audioLinks = @('https://r2.fivemanage.com/');
                        maxSeconds = 120; maxBytes = 15728640; cacheBytes = 209715200 }
    if ($old -and $old.Data) {
        foreach ($k in @('maxCalls', 'audioLinks', 'maxSeconds', 'maxBytes', 'cacheBytes')) {
            if ($null -ne $old.Data.$k) { $data[$k] = $old.Data.$k }
        }
    }
    if ($old -and $old.Token -and $old.Token.Length -ge 24 -and -not $NewKeys) {
        $data.token = $old.Token
        Good 'keeping its token'
    } else {
        $data.token = Random-Text 48 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
        Good 'made it a new random token'
    }
    $data.audioLinks = @($data.audioLinks)
    $json = $data | ConvertTo-Json -Depth 3
    $current = $null
    if (Test-Path $BotConfig) { try { $current = [IO.File]::ReadAllText($BotConfig) } catch { } }
    if ($current -ceq $json) {
        Good "$BotConfig is up to date. Recordings from: $($data.audioLinks -join ', '), and files resources ship"
    } else {
        [IO.File]::WriteAllText($BotConfig, $json, (New-Object Text.UTF8Encoding($false)))
        Good "wrote $BotConfig (locked to administrators and the service). Recordings from: $($data.audioLinks -join ', '), and files resources ship"
        $changed = $true
    }
    & icacls $BotConfig /inheritance:r /grant:r 'BUILTIN\Administrators:F' 'NT AUTHORITY\SYSTEM:F' 'NT AUTHORITY\LocalService:R' | Out-Null
    & icacls $BotDir /grant 'NT AUTHORITY\LocalService:(OI)(CI)RX' | Out-Null
    & icacls $BotLogDir /grant 'NT AUTHORITY\LocalService:(OI)(CI)M' | Out-Null

    # The service: made when missing; its settings applied either way (they take effect at its next start).
    if (-not $svc) { & $Nssm install $BotService $ours (Join-Path $BotApp 'bot.mjs') | Out-Null; $changed = $true }
    & $Nssm set $BotService DisplayName 'whip_voice voice bot' | Out-Null
    & $Nssm set $BotService Description "Plays lore characters' recorded lines into phone calls (whip_voice). Config: $BotConfig" | Out-Null
    & $Nssm set $BotService AppDirectory $BotApp | Out-Null
    & $Nssm set $BotService AppEnvironmentExtra "WHIP_VOICEBOT_CONFIG=$BotConfig" | Out-Null
    & $Nssm set $BotService Start SERVICE_AUTO_START | Out-Null
    & $Nssm set $BotService ObjectName 'NT AUTHORITY\LocalService' | Out-Null
    & $Nssm set $BotService AppStdout (Join-Path $BotLogDir 'voicebot.log') | Out-Null
    & $Nssm set $BotService AppStderr (Join-Path $BotLogDir 'voicebot.log') | Out-Null
    & $Nssm set $BotService AppRotateFiles 1 | Out-Null
    & $Nssm set $BotService AppRotateOnline 1 | Out-Null
    & $Nssm set $BotService AppRotateSeconds 86400 | Out-Null
    & $Nssm set $BotService AppRotateBytes 52428800 | Out-Null
    & $Nssm set $BotService AppExit Default Restart | Out-Null
    & $Nssm set $BotService AppRestartDelay 3000 | Out-Null
    # No firewall rule: it listens on 127.0.0.1 only, and reaches out (the voice room here, the recordings' site).
    # Started, restarted for a change, or left running.
    $svc = Get-Service -Name $BotService -ErrorAction SilentlyContinue
    if ($svc.Status -eq 'Running' -and -not $changed) {
        Good 'the voice bot was already running with this setup: left running'
    } elseif ($svc.Status -eq 'Running' -or $svc.Status -eq 'Paused') {
        # Paused: it kept stopping as it started and Windows gave up on it; a restart tries again.
        Nssm-Quiet "restart $BotService"
    } else {
        & $Nssm start $BotService | Out-Null
    }
    $h = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $h = Test-VoiceBot $data.token
        if ($h.Ok) { break }
    }
    if ($h.Ok) { Good "the voice bot is running (at most $($h.Max) calls at once)" }
    else { Bad "the voice bot did not answer on 127.0.0.1:7899. Look in $BotLogDir\voicebot.log." }
    return $data.token
}

Step '6. The voice bot (lore characters phoning players)'
Say '  It plays recorded lines into phone calls as the Director''s lore characters: one small service here, with its'
Say '  own Node.js in its own folder (about 100 MB).'
$BotToken = Install-VoiceBot

# --- 7. The certificate, and the check ----------------------------------------------------------------
Step '7. Checking everything'
if (-not $SkipCaddy -and ($IsIp -or (@(Resolve-Public $Address) -contains $PublicIp))) {
    Say '  Waiting for the certificate (Caddy fetches it the first time; up to a minute or two)...'
    $https = $null
    for ($i = 0; $i -lt 24; $i++) {
        $https = Test-Https $Address
        if ($https.Ok) { break }
        Start-Sleep -Seconds 5
    }
}
$found = @(& (Join-Path $PSScriptRoot 'check.ps1') -Domain $Address -InstallDir $InstallDir -SkipCaddy:$SkipCaddy -FromInstaller)[-1]

# --- 8. server.cfg ---------------------------------------------------------------------------------
Step '8. server.cfg'
$lines = @(
    "set whip_voice_url    `"wss://$Address`"",
    "set whip_voice_key    `"$ApiKey`"",
    "set whip_voice_secret `"$ApiSecret`""
)
if ($BotToken) { $lines += "set whip_voicebot_token `"$BotToken`"" }
$written = $false
# The server.cfg of the FiveM server this whip_voice is in (the folder above "resources"), unless -ServerCfg names
# others. Each gets a backup beside it.
$targets = @($ServerCfg -split ';' | ForEach-Object { Get-CleanPath $_ } | Where-Object { $_ })
if ($targets.Count -eq 0) {
    $own = Find-ServerCfg $PSScriptRoot
    if ($own) { $targets = @($own) }
}
$categories = @(Get-VoiceCategories $PSScriptRoot)
foreach ($p in $targets) {
    if (-not (Test-Path -LiteralPath $p)) { Warn "$p does not exist"; continue }
    $result = Update-ServerCfg $p "wss://$Address" $ApiKey $ApiSecret $BotToken $categories
    Good "$p updated (the old one is kept as $($result.Backup))"
    foreach ($n in $result.Notes) { Say "         - $n" 'Gray' }
    $written = $true
}
if ($written) {
    Say '  Two FiveM servers on this machine (Legacy and Enhanced)? Run this again from the other one''s whip_voice\service:'
    Say '  it keeps the same keys and puts the same lines in that server.cfg.'
} else {
    Say '  No server.cfg found above this resources folder. Open your server.cfg in Notepad and put these lines in it, after "ensure whip_core":' 'Cyan'
    Say ''
    foreach ($l in $lines) { Say "      $l" 'White' }
    Say '      ensure whip_voice' 'White'
    Say ''
    Say '  - Already has any of these lines (an older whip_voice_url, _key, _secret or whip_voicebot_token)? Replace'
    Say '    them: never two of the same.'
    Say '  - Has "setr sv_mumble true"? Put # in front of it: whip_voice does not use it, and on, it is insecure.'
    Say '  - Plain "set", never "setr": the secret and the token must stay on the server.'
    Say '  - Two FiveM servers on this machine (Legacy and Enhanced)? Both server.cfg files get the same lines.'
    Say '  - Save, then restart that FiveM server.'
    try { (($lines + 'ensure whip_voice') -join "`r`n") | Set-Clipboard; Good 'the lines are on your clipboard too: Ctrl+V to paste them' } catch { }
}

Say ''
if ($found -eq 0) { Say '  All done. Restart your FiveM server (txAdmin > Restart) and voice is on.' 'Green' }
else { Say "  Nearly: $found thing(s) above still need fixing. Fix them, then double-click ""Check voice server.bat""." 'Yellow' }
Say '  In game, an admin can type /voicecheck at any time: it checks the voice from every player''s side.'
Say "  The LiveKit service: Services > ""LiveKit voice server"" (or: $Nssm restart $ServiceName)."
if ($BotToken) { Say "  The voice bot: Services > ""whip_voice voice bot"" (or: $Nssm restart $BotService)." }

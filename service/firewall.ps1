# ============================================
# whip_voice - Windows Firewall and the BUILT-IN voice server
# ============================================
#
# Players' games send their voices to the built-in voice server (whip_voice\bin\livekit\livekit-server.exe) over UDP
# 7882-7893, and TCP 7881 when UDP is blocked. This opens those ports inbound, and takes away any BLOCK rule Windows
# made for the voice server when someone answered Cancel to its "allow access?" box: in Windows Firewall a block beats
# every allow, so the ports alone would not let voices in.
#
# THE EASY WAY: double-click "Open voice ports.bat" next to this file (it asks for administrator rights).
# whip_voice also runs this at every start and for /voicecheck: it reads the firewall then, and opens the ports itself
# only when the FiveM server runs as administrator.
#
# Options (all optional):
#   -Exe <path>    the voice server's program (default: ..\bin\livekit\livekit-server.exe from this folder)
#   -Udp 7882-7893 -Tcp 7881    the ports, when server.cfg changed them (whip_voice_udp, whip_voice_tcp)
#   -Fix           open them (and remove the blocks) if they need it and this runs as administrator
#   -Json          one line of JSON at the end, for whip_voice

param(
    [string]$Exe = '',
    [string]$Udp = '7882-7893',
    [string]$Tcp = '7881',
    [switch]$Fix,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
if (-not $Exe) { $Exe = Join-Path $PSScriptRoot '..\bin\livekit\livekit-server.exe' }
$Exe = [IO.Path]::GetFullPath($Exe)

# Named by their ports: two FiveM servers on one machine (other ports for the second, docs/SETUP.md) each keep their own.
$RuleUdp = "ALLOW whip_voice built-in voice server (UDP $Udp)"
$RuleTcp = "ALLOW whip_voice built-in voice server (TCP $Tcp)"

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

#--- Which profiles the machine's networks are on now: Domain, Private, Public.
function Get-ActiveProfiles {
    $p = @()
    foreach ($c in @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
        switch ("$($c.NetworkCategory)") {
            'DomainAuthenticated' { $p += 'Domain' }
            'Private' { $p += 'Private' }
            'Public' { $p += 'Public' }
        }
    }
    if ($p.Count -eq 0) { $p = @('Public') }
    return @($p | Select-Object -Unique)
}

#--- Does a rule's profile cover every active one?
function Test-Covers($rule, [string[]]$profiles) {
    $have = "$($rule.Profile)"
    if ($have -eq 'Any') { return $true }
    foreach ($p in $profiles) { if ($have -notmatch $p) { return $false } }
    return $true
}

#--- How it stands: on, open, blocked (and the rules behind it).
function Read-Firewall {
    $on = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { "$($_.Enabled)" -eq 'True' }).Count -gt 0
    $profiles = Get-ActiveProfiles
    # The rules Windows (or anyone) made for the voice server's program itself.
    $forProgram = @(Get-NetFirewallApplicationFilter -Program $Exe -ErrorAction SilentlyContinue |
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { "$($_.Direction)" -eq 'Inbound' -and "$($_.Enabled)" -eq 'True' })
    $blocks = @($forProgram | Where-Object { "$($_.Action)" -eq 'Block' })
    $programAllowed = @($forProgram | Where-Object { "$($_.Action)" -eq 'Allow' -and (Test-Covers $_ $profiles) }).Count -gt 0
    # Ours: the ports, for any program.
    $ours = @(Get-NetFirewallRule -DisplayName @($RuleUdp, $RuleTcp) -ErrorAction SilentlyContinue |
        Where-Object { "$($_.Enabled)" -eq 'True' -and "$($_.Action)" -eq 'Allow' })
    $portsOk = $false
    if ($ours.Count -ge 2) {
        $ports = @($ours | Get-NetFirewallPortFilter | ForEach-Object { "$($_.Protocol) $($_.LocalPort -join ',')" })
        $portsOk = ($ports -contains "UDP $Udp") -and ($ports -contains "TCP $Tcp")
    }
    return [pscustomobject]@{
        on = $on; open = ($portsOk -or $programAllowed); blocked = ($blocks.Count -gt 0); ports = $portsOk
        program = $programAllowed; profiles = ($profiles -join ', '); Blocks = $blocks
    }
}

$result = [ordered]@{ on = $false; open = $false; blocked = $false; admin = $admin; fixed = $false; unblocked = $false; error = $null }
try {
    $f = Read-Firewall
    $result.on = $f.on; $result.open = $f.open; $result.blocked = $f.blocked
    $needs = $f.on -and ($f.blocked -or -not $f.ports)
    if ($Fix -and $needs -and $admin) {
        foreach ($b in $f.Blocks) { Remove-NetFirewallRule -Name $b.Name }
        Get-NetFirewallRule -DisplayName @($RuleUdp, $RuleTcp) -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $RuleUdp -Direction Inbound -Action Allow -Protocol UDP -LocalPort $Udp -Profile Any `
            -Description "Players' voices to whip_voice's built-in voice server (LiveKit)." | Out-Null
        New-NetFirewallRule -DisplayName $RuleTcp -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Tcp -Profile Any `
            -Description "Players' voices to whip_voice's built-in voice server (LiveKit), when their network blocks UDP." | Out-Null
        $result.unblocked = $f.Blocks.Count -gt 0
        $f = Read-Firewall
        $result.open = $f.open; $result.blocked = $f.blocked
        $result.fixed = $f.open -and -not $f.blocked
    }
} catch {
    $result.error = "$($_.Exception.Message)"
}

if ($Json) {
    ($result | ConvertTo-Json -Compress)
    return
}

Write-Host ''
if ($result.error) {
    Write-Host "  Could not read Windows Firewall: $($result.error)" -ForegroundColor Red
} elseif (-not $result.on) {
    Write-Host '  Windows Firewall is off on this machine: nothing to open here.' -ForegroundColor Green
} elseif ($result.open -and -not $result.blocked) {
    if ($result.fixed) { Write-Host "  Opened UDP $Udp and TCP $Tcp for voice$(if ($result.unblocked) { ", and took away Windows' block on the voice server" })." -ForegroundColor Green }
    else { Write-Host "  Windows Firewall already lets voices in (UDP $Udp, TCP $Tcp)." -ForegroundColor Green }
} elseif (-not $admin) {
    Write-Host '  This needs administrator rights: double-click "Open voice ports.bat" (it asks for them).' -ForegroundColor Yellow
} else {
    Write-Host '  Windows Firewall still does not let voices in. Look for rules blocking livekit-server.exe in' -ForegroundColor Red
    Write-Host '  "Windows Defender Firewall with Advanced Security" > Inbound Rules (a group policy may set them).' -ForegroundColor Red
}
Write-Host ''
Write-Host '  Your HOST may have a firewall of its own too, in its website''s control panel (OVH, Hetzner, AWS, Azure,'
Write-Host "  Google Cloud, ...). If it does, allow these INBOUND there, as you did for 30120:"
Write-Host ''
Write-Host "      UDP $Udp      voices" -ForegroundColor White
Write-Host "      TCP $Tcp           voices, when a player's network blocks UDP" -ForegroundColor White
Write-Host ''
Write-Host '  Nothing to restart. In game, /voicecheck (an admin) says whether players get through.'

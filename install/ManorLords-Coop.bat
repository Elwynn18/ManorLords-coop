<# : Manor Lords Co-op - double-cliquez sur ce fichier pour installer, mettre a jour ou desinstaller le mod.
@echo off
setlocal
set "COOP_SELF=%~f0"
set "COOP_HERE=%~dp0"
set "COOP_ARGS=%*"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:COOP_SELF,[Text.Encoding]::UTF8); & ([ScriptBlock]::Create($s))"
if errorlevel 1 pause
exit /b
#>
# ---------------------------------------------------------------------------------------------
# Manor Lords Co-op : installation, mise à jour et désinstallation pour Windows.
# Ce fichier est à la fois un .bat (les lignes ci-dessus) et un script PowerShell (la suite).
# Il trouve Steam et Manor Lords, vérifie la version du jeu, installe UE4SS (fourni dans
# l'archive, version figée) et le mod, écrit config.txt. Il n'écrit que dans le dossier du jeu.
# Options : install | uninstall  -GameDir <dossier>  -Yes
# ---------------------------------------------------------------------------------------------
$AppId = 1363080
$ExeSha = '560451df38cd91134026c25b69539449c570f3163e33bc8c45b4dc20b6952cee'
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Here = $env:COOP_HERE
$Payload = Join-Path $Here 'payload'

$Action = ''; $GameDir = ''; $Yes = $false
$argList = @()
if ($env:COOP_ARGS) { $argList = @([regex]::Matches($env:COOP_ARGS, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') }) }
for ($i = 0; $i -lt $argList.Count; $i++) {
    switch -Regex ($argList[$i]) {
        '^(install|update)$' { $Action = 'install' }
        '^uninstall$' { $Action = 'uninstall' }
        '^-+gamedir$' { $i++; $GameDir = $argList[$i] }
        '^-+yes$|^-y$' { $Yes = $true }
    }
}
function Ok([string]$t) { Write-Host '  √ ' -NoNewline -ForegroundColor Green; Write-Host $t }
function Warn([string]$t) { Write-Host '  ! ' -NoNewline -ForegroundColor Yellow; Write-Host $t }
function Die([string]$t) { Write-Host "  × $t" -ForegroundColor Red; exit 1 }
function Ask([string]$q, [string]$def) {
    if ($Yes) { return $def }
    $r = Read-Host "  $q [$def]"
    if ([string]::IsNullOrWhiteSpace($r)) { return $def } else { return $r.Trim() }
}

Write-Host ''
Write-Host '  ✦ MANOR LORDS CO-OP ✦  installation · mise à jour · désinstallation (Windows)' -ForegroundColor Cyan
Write-Host ''
if (-not (Test-Path (Join-Path $Payload 'ManorLordsCoop'))) { Die "dossier payload introuvable : décompressez toute l'archive avant de lancer ce fichier" }

# ------------------------------------------------------------------ trouver le jeu
function Find-Game {
    $steam = $null
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try { $v = Get-ItemProperty -Path $k -ErrorAction Stop; if ($v.SteamPath) { $steam = $v.SteamPath }; if ($v.InstallPath) { $steam = $v.InstallPath } } catch {}
        if ($steam) { break }
    }
    if (-not $steam) { return $null }
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value.Replace('\\', '\') }
    }
    foreach ($l in $libs) {
        $acf = Join-Path $l "steamapps\appmanifest_$AppId.acf"
        if (Test-Path $acf) {
            $m = [regex]::Match((Get-Content $acf -Raw), '"installdir"\s+"([^"]+)"')
            if ($m.Success) { $d = Join-Path $l ("steamapps\common\" + $m.Groups[1].Value); if (Test-Path $d) { return $d } }
        }
    }
    return $null
}
if (-not $GameDir) { $GameDir = Find-Game }
if (-not $GameDir -or -not (Test-Path $GameDir)) { Die 'Manor Lords introuvable. Relancez avec : ManorLords-Coop.bat -GameDir "C:\...\Manor Lords"' }
$Win64 = Join-Path $GameDir 'ManorLords\Binaries\Win64'
$Exe = Join-Path $Win64 'ManorLords-Win64-Shipping.exe'
if (-not (Test-Path $Exe)) { Die "jeu incomplet : $Exe manque" }
Ok "jeu : $GameDir"
$ModDir = Join-Path $Win64 'ue4ss\Mods\ManorLordsCoop'
$Mark = Join-Path $Win64 'ue4ss\.installed-by-manorlords-coop'
$ModsTxt = Join-Path $Win64 'ue4ss\Mods\mods.txt'

if (-not $Action) {
    if (Test-Path $ModDir) { $r = Ask "Le mod est installé. (i)nstaller/mettre à jour ou (d)ésinstaller ?" 'i' } else { $r = 'i' }
    if ($r -match '^[dD]') { $Action = 'uninstall' } else { $Action = 'install' }
}

# ------------------------------------------------------------------ désinstaller
if ($Action -eq 'uninstall') {
    if (Test-Path $ModDir) { Remove-Item -Recurse -Force $ModDir }
    if (Test-Path $ModsTxt) { (Get-Content $ModsTxt) | Where-Object { $_ -notmatch '^ManorLordsCoop\s*:' } | Set-Content $ModsTxt -Encoding ASCII }
    Ok 'mod retiré'
    if (Test-Path $Mark) {
        $r = Ask 'Retirer aussi UE4SS (installé par ce programme) ? (o/n)' 'o'
        if ($r -match '^[oOyY]') { Remove-Item -Recurse -Force (Join-Path $Win64 'ue4ss'); Remove-Item -Force (Join-Path $Win64 'dwmapi.dll'); Ok 'UE4SS retiré' }
    }
    exit 0
}

# ------------------------------------------------------------------ installer
Write-Host '  vérification de la version du jeu…'
$got = (Get-FileHash -Algorithm SHA256 $Exe).Hash.ToLower()
if ($got -ne $ExeSha) { Die "version du jeu non prise en charge (empreinte $got). Ce mod demande Manor Lords, build Steam 26185246." }
Ok 'version du jeu : build Steam 26185246'

$ue = Join-Path $Win64 'ue4ss\UE4SS.dll'
if ((Test-Path $ue) -and (Test-Path (Join-Path $Win64 'dwmapi.dll'))) {
    $same = (Get-FileHash $ue).Hash -eq (Get-FileHash (Join-Path $Payload 'ue4ss\ue4ss\UE4SS.dll')).Hash
    if ($same) { Ok 'UE4SS déjà installé (même version)' } else { Warn 'un autre UE4SS est déjà installé : il est gardé. Si le mod ne démarre pas, désinstallez-le et relancez ce programme.' }
} else {
    Copy-Item -Recurse -Force (Join-Path $Payload 'ue4ss\ue4ss') $Win64
    Copy-Item -Force (Join-Path $Payload 'ue4ss\dwmapi.dll') $Win64
    New-Item -ItemType File -Force $Mark | Out-Null
    Ok 'UE4SS installé (version figée fournie avec le mod)'
}

$keep = $null
$cfg = Join-Path $ModDir 'config.txt'
if (Test-Path $cfg) { $keep = Get-Content $cfg -Raw }
if (Test-Path $ModDir) { Remove-Item -Recurse -Force $ModDir }
Copy-Item -Recurse -Force (Join-Path $Payload 'ManorLordsCoop') $ModDir
$lines = @(); if (Test-Path $ModsTxt) { $lines = @(Get-Content $ModsTxt | Where-Object { $_ -notmatch '^ManorLordsCoop\s*:' }) }
$out = @(); $done = $false
foreach ($l in $lines) { if (-not $done -and $l -match '^Keybinds') { $out += 'ManorLordsCoop : 1'; $done = $true }; $out += $l }
if (-not $done) { $out += 'ManorLordsCoop : 1' }
$out | Set-Content $ModsTxt -Encoding ASCII
Ok 'mod installé et activé'

if ($keep) {
    Set-Content $cfg $keep -Encoding UTF8
    Ok 'réglages précédents gardés'
} else {
    $r = Ask "Vous êtes l'hôte (h) ou l'invité (i) ?" 'i'
    $role = 'host'; if ($r -match '^[iIjJ]') { $role = 'join' }
    $addr = '127.0.0.1'; if ($role -eq 'join') { $addr = Ask "Adresse de l'hôte (IP ou nom) ?" '127.0.0.1' }
    $lord = Ask 'Nom de votre seigneur ?' $env:USERNAME
    @("role = $role", "address = $addr", 'port = 27015', "lord = $lord", 'region =') | Set-Content $cfg -Encoding UTF8
    Ok "réglages écrits (role=$role, seigneur=$lord)"
    if ($role -eq 'host') { Warn "L'hôte doit laisser passer le port 27015 (TCP) : pare-feu Windows et box, ou un réseau privé (Tailscale, ZeroTier)." }
}
Write-Host ''
Write-Host '  Terminé. Lancez Manor Lords depuis Steam. L''état du mod s''écrit dans :'
Write-Host "  $ModDir\run\status.txt"
Write-Host ''
if (-not $Yes) { Read-Host '  Appuyez sur Entrée pour fermer' | Out-Null }
exit 0

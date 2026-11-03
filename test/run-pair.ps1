# Lab test on one Windows PC: two copies of the game (host + guest over 127.0.0.1) run a bot scenario
# of the Lua mod (COOP_TEST), then the STATE lines of both sides are compared.
#   .\run-pair.ps1 mirror|fields|roads|aibuild|hoverrm
#   .\run-pair.ps1 manual -Manual     both copies start and stay up (host starts a new game, no bot
#                                     actions): play the host window with the mouse, watch the guest
# Closes any running copy of the game first. Needs the mod installed in the game (ManorLords-Coop.bat,
# or lua\ManorLordsCoop plus native\out\coopnative.dll copied into Binaries\Win64\ue4ss\Mods).
param([Parameter(Mandatory)][string]$Scenario, [int]$TimeoutSec = 480, [switch]$Manual, [string]$Game = '')
$ErrorActionPreference = 'Stop'

function Find-Game {
    $steam = (Get-ItemProperty HKCU:\Software\Valve\Steam -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return $null }
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        $libs += Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' }
    }
    foreach ($l in $libs) {
        $acf = Join-Path $l 'steamapps\appmanifest_1363080.acf'
        if (Test-Path $acf) {
            $dir = (Select-String -Path $acf -Pattern '"installdir"\s+"([^"]+)"').Matches[0].Groups[1].Value
            $p = Join-Path $l "steamapps\common\$dir"
            if (Test-Path $p) { return $p }
        }
    }
    return $null
}
if (-not $Game) { $Game = Find-Game }
if (-not $Game -or -not (Test-Path $Game)) { throw 'Manor Lords not found: pass -Game "<folder of Manor Lords>"' }
$w = Join-Path $Game 'ManorLords\Binaries\Win64'
$m = Join-Path $w 'ue4ss\Mods\ManorLordsCoop'
$exe = Join-Path $w 'ManorLords-Win64-Shipping.exe'

function Stop-Game {
    foreach ($p in @(Get-Process -Name 'ManorLords-Win64-Shipping' -ErrorAction SilentlyContinue)) {
        $null = $p.CloseMainWindow()
        if (-not $p.WaitForExit(20000)) { Stop-Process -Id $p.Id -Force -Confirm:$false }
    }
}
function Start-Copy([hashtable]$vars, [int]$x) {
    foreach ($k in $vars.Keys) { Set-Item "env:$k" $vars[$k] }
    Start-Process -FilePath $exe -WorkingDirectory $w -ArgumentList '-windowed', '-ResX=1270', '-ResY=700', "-WinX=$x", '-WinY=40' | Out-Null
    foreach ($k in $vars.Keys) { Remove-Item "env:$k" }
}

Stop-Game
Start-Sleep 3
Remove-Item (Join-Path $m 'run'), (Join-Path $m 'run-guest') -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $m 'run-guest') | Out-Null
$hs = Join-Path $m 'run\status.txt'
$gs = Join-Path $m 'run-guest\status.txt'

Start-Copy @{ COOP_TEST = $Scenario; COOP_ROLE = 'host'; COOP_LORD = 'HostLord' } 0          # left half
$deadline = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $deadline -and -not ((Get-Content $hs -ErrorAction SilentlyContinue) -match 'NET listening')) { Start-Sleep 5 }

$g = Join-Path $m 'run-guest'
Start-Copy @{ COOP_TEST = $Scenario; COOP_ROLE = 'join'; COOP_LORD = 'GuestLord'; COOP_ADDRESS = '127.0.0.1'
              COOP_STATUS = "$g\status.txt"; COOP_NATIVE_IN = "$g\inbox.txt"; COOP_NATIVE_OUT = "$g\outbox.txt"
              COOP_NATIVE_LOG = "$g\native.log"; COOP_GUESTS = "$g\guests.txt" } 1280   # right half
if ($Manual) { Write-Host "both copies started; host log: $hs, guest log: $gs"; return }

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    Start-Sleep 10
    $h = Get-Content $hs -ErrorAction SilentlyContinue; $gl = Get-Content $gs -ErrorAction SilentlyContinue
    if (($h -match 'RESULT:') -and ($gl -match 'RESULT:')) { break }
    if (@(Get-Process -Name 'ManorLords-Win64-Shipping' -ErrorAction SilentlyContinue).Count -lt 2) { Write-Host 'a game copy exited early'; break }
}
$h = @(Get-Content $hs -ErrorAction SilentlyContinue); $gl = @(Get-Content $gs -ErrorAction SilentlyContinue)
Write-Host "=== HOST"; $h | ForEach-Object { Write-Host "  $_" }
Write-Host "=== GUEST"; $gl | ForEach-Object { Write-Host "  $_" }

# compare the world facts both sides printed (sorted: each side lists its own lord last)
$facts = { param($l) $l | Where-Object { $_ -match '^(STATE|ROADSTATE|SHAPE)' } | Sort-Object }
$hf = & $facts $h; $gf = & $facts $gl
$diff = Compare-Object @($hf) @($gf)
$pass = ($h -match 'RESULT: PASS') -and ($gl -match 'RESULT: PASS') -and -not $diff
Write-Host ("=== {0}: {1} fact lines per side, {2} differ" -f $(if ($pass) { 'PASS' } else { 'FAIL' }), $hf.Count, @($diff).Count)
$diff | ForEach-Object { Write-Host ("  {0} {1}" -f $(if ($_.SideIndicator -eq '<=') { 'host only: ' } else { 'guest only:' }), $_.InputObject) }
Stop-Game

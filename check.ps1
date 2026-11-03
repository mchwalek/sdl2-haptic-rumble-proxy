<#
.SYNOPSIS
Checks whether the rumble proxy can fix rumble for a game.

.DESCRIPTION
Scans the game folder for modules that import SDL2.dll, reads which SDL
functions they use and prints a verdict:
  PROXY APPLIES    the game rumbles through SDL_HapticRumblePlay
  UPGRADE SDL2     the game already uses SDL_JoystickRumble/SDL_GameControllerRumble
  NOT APPLICABLE   no SDL2 rumble path the proxy can change
Only static imports are visible. A game that loads SDL2.dll with
LoadLibrary/GetProcAddress, or links SDL statically, shows as not applicable.

.EXAMPLE
.\check.ps1 'C:\Games\Dead Cells'
#>
param([Parameter(Mandatory)] [string]$Path)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\tools\pe.ps1"

$Path = (Resolve-Path $Path).Path
$files = Get-ChildItem $Path -Recurse -File -Include *.exe, *.dll, *.hdll, *.ndll, *.pyd -ErrorAction SilentlyContinue

$sdlUsers = @(); $otherInput = @(); $sdlDlls = @(); $sdl3 = @()
foreach ($f in $files) {
    try { $pe = Read-PeFile $f.FullName; $imports = @(Get-PeImports $pe) } catch { continue }
    $rel = $f.FullName.Substring($Path.Length).TrimStart('\')
    if ($f.Name -ieq 'SDL2.dll') { $sdlDlls += [pscustomobject]@{ Rel = $rel; Pe = $pe; File = $f } }
    if ($f.Name -ieq 'SDL3.dll') { $sdl3 += $rel }
    $sdlImport = $imports | Where-Object { $_.Dll -ieq 'SDL2.dll' }
    if ($sdlImport) {
        $sdlUsers += [pscustomobject]@{ Rel = $rel; Arch = $pe.Arch; Functions = @($sdlImport | ForEach-Object Functions) }
    }
    if ($imports | Where-Object { $_.Dll -match '^(xinput|dinput8)' }) { $otherInput += $rel }
}

function Verdict([string]$Kind, [string]$Why) {
    Write-Host ''
    Write-Host "Verdict: $Kind" -ForegroundColor $(switch ($Kind) { 'PROXY APPLIES' { 'Green' } 'UPGRADE SDL2' { 'Yellow' } default { 'Red' } })
    Write-Host "  $Why"
}

Write-Host "Game folder: $Path"
foreach ($d in $sdlDlls) {
    $exports = @(Get-PeExports $d.Pe)
    $version = $d.File.VersionInfo.FileVersion
    $state = if ($exports | Where-Object { $_.Forwarder -like '_SDL2_real.*' }) { ', rumble proxy installed' } else { '' }
    $real = Join-Path $d.File.DirectoryName '_SDL2_real.dll'
    $hasRumble = if ($state -and (Test-Path $real)) {
        $version = (Get-Item $real).VersionInfo.FileVersion
        @(Get-PeExports (Read-PeFile $real)).Name -contains 'SDL_JoystickRumble'
    } else { $exports.Name -contains 'SDL_JoystickRumble' }
    Write-Host "SDL2.dll: $($d.Rel) ($($d.Pe.Arch), version $version$state, SDL_JoystickRumble: $(if ($hasRumble) { 'yes' } else { 'no, needs SDL 2.0.9+' }))"
}
foreach ($u in $sdlUsers) {
    $rumble = @($u.Functions | Where-Object { $_ -match 'Rumble|^SDL_Haptic' })
    Write-Host "Imports SDL2.dll: $($u.Rel) ($($u.Arch)); rumble-related: $(if ($rumble) { $rumble -join ', ' } else { 'none' })"
}
if ($otherInput) { Write-Host "Imports XInput/DirectInput directly: $($otherInput -join ', ')" }

$all = @($sdlUsers | ForEach-Object Functions | Sort-Object -Unique)
if (-not $sdlUsers) {
    if ($sdl3) { Verdict 'NOT APPLICABLE' "The game uses SDL3 ($($sdl3 -join ', ')); this proxy targets SDL2." }
    elseif ($sdlDlls) { Verdict 'NOT APPLICABLE' 'SDL2.dll is present but no module imports it statically; the game may load it at runtime. Try the proxy at your own risk.' }
    else { Verdict 'NOT APPLICABLE' 'No module imports SDL2.dll. The game uses another input library or links SDL statically.' }
}
elseif ($all -contains 'SDL_JoystickRumble' -or $all -contains 'SDL_GameControllerRumble') {
    Verdict 'UPGRADE SDL2' 'The game already calls SDL_JoystickRumble/SDL_GameControllerRumble. Replace SDL2.dll with a current official SDL2 2.x release of the same architecture; no proxy needed.'
}
elseif ($all -contains 'SDL_HapticRumblePlay') {
    $arch = ($sdlUsers | Select-Object -First 1).Arch
    Verdict 'PROXY APPLIES' "The game rumbles through SDL_HapticRumblePlay. Build the proxy against an official $arch SDL2.dll (build.ps1) and install it."
}
elseif ($all | Where-Object { $_ -like 'SDL_Haptic*' }) {
    Verdict 'NOT APPLICABLE' 'The game uses custom haptic effects (SDL_HapticNewEffect/RunEffect), not simple rumble. The proxy only converts SDL_HapticRumble* calls.'
}
else {
    Verdict 'NOT APPLICABLE' 'The game imports SDL2.dll but never calls an SDL rumble function.'
}
if ($sdlUsers.Count -gt 0 -and $otherInput) {
    Write-Host '  Note: some executables use XInput/DirectInput instead of SDL. Launch the one that loads SDL2 (for example deadcells_gl.exe, not deadcells.exe).'
}

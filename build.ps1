<#
.SYNOPSIS
Builds the rumble proxy SDL2.dll for a given official SDL2.dll.

.DESCRIPTION
Reads the export table of the real SDL2.dll, generates a .def file that
forwards every export to _SDL2_real.dll except the functions implemented in
src\proxy.c, compiles with Zig, then checks the result and test-loads it.

The output folder holds the two files to copy into the game folder:
  SDL2.dll        the proxy
  _SDL2_real.dll  a copy of the SDL2.dll you passed in

.EXAMPLE
.\build.ps1 -SdlDll C:\Downloads\SDL2-2.32.10-win32-x86\SDL2.dll
#>
param(
    [Parameter(Mandatory)] [string]$SdlDll,
    [string]$Out,
    [string]$Zig = 'zig'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\tools\pe.ps1"

$SdlDll = (Resolve-Path $SdlDll).Path
$sdl = Read-PeFile $SdlDll
$arch = $sdl.Arch
if ($arch -notin 'x86', 'x64') { throw "Unsupported SDL2.dll architecture: $arch" }
if (-not $Out) { $Out = Join-Path $PSScriptRoot "build\$arch" }
$Out = [IO.Path]::GetFullPath($Out)

$exports = @(Get-PeExports $sdl | Where-Object { -not $_.Forwarder } | ForEach-Object Name)
if ($exports -notcontains 'SDL_JoystickRumble') {
    throw "This SDL2.dll has no SDL_JoystickRumble (added in SDL 2.0.9). Use a current SDL2 2.x release."
}

$source = Join-Path $PSScriptRoot 'src\proxy.c'
$overrides = @([regex]::Matches((Get-Content $source -Raw), 'PROXY_API\s+[^(;]*?\b(SDL_\w+)\s*\(') | ForEach-Object { $_.Groups[1].Value })
$missing = $overrides | Where-Object { $exports -notcontains $_ }
if ($missing) { throw "SDL2.dll does not export: $($missing -join ', ')" }

# lld prepends an underscore to forward targets on x86, so "SDL2_real.X" becomes "_SDL2_real.X".
# On x64 it does not. Either way the verified result is "_SDL2_real.X".
$target = if ($arch -eq 'x86') { 'SDL2_real' } else { '_SDL2_real' }
$def = @('LIBRARY SDL2', 'EXPORTS') + ($exports | ForEach-Object {
    if ($overrides -contains $_) { "    $_" } else { "    $_ = $target.$_" }
})
New-Item -ItemType Directory -Force $Out | Out-Null
$defPath = Join-Path $Out 'SDL2.def'
Set-Content -Path $defPath -Value $def -Encoding ascii

$proxy = Join-Path $Out 'SDL2.dll'
$zigTarget = if ($arch -eq 'x86') { 'x86-windows-gnu' } else { 'x86_64-windows-gnu' }
& $Zig cc -target $zigTarget -shared -O2 -o $proxy $source $defPath
if ($LASTEXITCODE -ne 0) { throw "zig cc failed with exit code $LASTEXITCODE" }

# Check the export table of the result.
$built = Read-PeFile $proxy
if ($built.Arch -ne $arch) { throw "Proxy is $($built.Arch), expected $arch" }
$builtExports = @(Get-PeExports $built)
$problems = @()
if ($builtExports.Count -ne $exports.Count) { $problems += "export count $($builtExports.Count), expected $($exports.Count)" }
foreach ($e in $builtExports) {
    $expected = if ($overrides -contains $e.Name) { $null } else { "_SDL2_real.$($e.Name)" }
    if ($exports -notcontains $e.Name) { $problems += "unexpected export $($e.Name)" }
    elseif ($e.Forwarder -ne $expected) { $problems += "$($e.Name) forwards to '$($e.Forwarder)', expected '$expected'" }
}
if ($problems) { throw "Proxy export table is wrong:`n  $($problems[0..19] -join "`n  ")" }

Copy-Item $SdlDll (Join-Path $Out '_SDL2_real.dll') -Force

# Load the proxy in a PowerShell of the same architecture and resolve one forwarded and one own export.
$hostExe = if ($arch -eq 'x86' -and [Environment]::Is64BitOperatingSystem) {
    "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
} else {
    "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
}
$probe = @"
`$ProgressPreference = 'SilentlyContinue'
`$sig = '[DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr LoadLibraryExW(string p, IntPtr f, uint flags);
[DllImport("kernel32", CharSet=CharSet.Ansi)] public static extern IntPtr GetProcAddress(IntPtr m, string n);'
`$k = Add-Type -MemberDefinition `$sig -Name K -Namespace P -PassThru
`$m = `$k::LoadLibraryExW('$proxy', [IntPtr]::Zero, 0x1100)
if (`$m -eq [IntPtr]::Zero) { Write-Output "LoadLibrary failed: `$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"; exit 1 }
foreach (`$n in 'SDL_Init', 'SDL_HapticRumblePlay') { if (`$k::GetProcAddress(`$m, `$n) -eq [IntPtr]::Zero) { Write-Output "GetProcAddress `$n failed"; exit 1 } }
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
$result = & $hostExe -NoProfile -NonInteractive -EncodedCommand $encoded
if ($LASTEXITCODE -ne 0) { throw "Load test failed: $result" }

Write-Host "Built $arch proxy for $($exports.Count) exports ($($overrides.Count) implemented, rest forwarded)."
Write-Host "Copy these into the game folder (after backing up its SDL2.dll):"
Write-Host "  $proxy"
Write-Host "  $(Join-Path $Out '_SDL2_real.dll')"

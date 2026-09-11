# Install "Achievement Switch" into the Isaac mods folder.
#
# The script is deliberately pure ASCII: Windows PowerShell 5.1 reads .ps1 files
# as ANSI unless they carry a UTF-8 BOM, which garbles non-ASCII text.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools\install.ps1
#   powershell -ExecutionPolicy Bypass -File tools\install.ps1 -GamePath "G:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth"

param(
    [string]$GamePath = "",
    [string]$ModName  = "achievement_switch"
)

$ErrorActionPreference = "Stop"
$source = Join-Path (Split-Path $PSScriptRoot -Parent) $ModName
if (-not (Test-Path (Join-Path $source "main.lua"))) {
    throw "Mod source not found: $source"
}

function Test-IsaacDir([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    try {
        return Test-Path ($dir.TrimEnd('\') + "\isaac-ng.exe")
    } catch {
        return $false   # a drive letter that does not exist throws; treat as "not here"
    }
}

function Get-SteamRoots {
    $roots = @()
    foreach ($base in @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam")) {
        if ($base -and (Test-Path $base)) { $roots += $base }
    }
    foreach ($vdf in @(
        "${env:ProgramFiles(x86)}\Steam\config\libraryfolders.vdf",
        "${env:ProgramFiles(x86)}\Steam\steamapps\libraryfolders.vdf")) {
        if ($vdf -and (Test-Path $vdf)) {
            foreach ($line in Get-Content $vdf) {
                if ($line -match '"path"\s+"([^"]+)"') {
                    $roots += ($matches[1] -replace '\\\\', '\')
                }
            }
        }
    }
    return $roots | Select-Object -Unique
}

function Find-Game {
    $rel = "steamapps\common\The Binding of Isaac Rebirth"
    $candidates = @()
    foreach ($root in Get-SteamRoots) { $candidates += ($root.TrimEnd('\') + "\" + $rel) }
    foreach ($root in @("G:\SteamLibrary", "D:\SteamLibrary", "E:\SteamLibrary", "F:\SteamLibrary", "C:\SteamLibrary")) {
        $candidates += ($root + "\" + $rel)
    }
    foreach ($c in $candidates) {
        if (Test-IsaacDir $c) { return (Resolve-Path $c).Path }
    }
    return $null
}

if (-not (Test-IsaacDir $GamePath)) {
    $found = Find-Game
    if (-not $found) {
        throw "Game folder not found. Pass -GamePath pointing at the folder that contains isaac-ng.exe"
    }
    $GamePath = $found
}

$target = Join-Path $GamePath ("mods\" + $ModName)
Write-Host "Game folder : $GamePath"
Write-Host "Install to  : $target"

if (Test-Path $target) {
    Remove-Item $target -Recurse -Force
}
New-Item -ItemType Directory -Path $target | Out-Null
foreach ($file in @("main.lua", "metadata.xml", "thumb.png")) {
    $from = Join-Path $source $file
    if (Test-Path $from) { Copy-Item $from $target -Force }
}

$rgon = Join-Path $GamePath "Repentogon"
if (Test-Path $rgon) {
    Write-Host "REPENTOGON  : installed" -ForegroundColor Green
} else {
    Write-Host "REPENTOGON  : NOT FOUND - install it, or only the seed channel will work" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. Launch the game through REPENTOGONLauncher.exe." -ForegroundColor Green
Write-Host "In game press ~ to open the debug console, then open 'Achievement Switch' in the top menu bar."
Write-Host "(The Mod Config Menu entry is hidden by default; enable it from the Repentogon menu if you want it.)"

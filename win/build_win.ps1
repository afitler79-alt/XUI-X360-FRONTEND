Param(
    [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$OutDir = (Join-Path $PSScriptRoot "dist"),
    [string]$BundleName = "XUI-Windows-Bundle"
)

$ErrorActionPreference = "Stop"

function Copy-IfExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (Test-Path $Path) {
        Copy-Item -Path $Path -Destination $Destination -Recurse -Force
        return $true
    }
    return $false
}

Write-Host "[INFO] Building Windows distribution bundle..."
Write-Host "[INFO] SourceRoot: $SourceRoot"
Write-Host "[INFO] OutDir: $OutDir"

$required = @("xui11.sh.fixed.sh")
foreach ($f in $required) {
    $p = Join-Path $SourceRoot $f
    if (-not (Test-Path $p)) {
        throw "Missing required file: $p"
    }
}

$stageDir = Join-Path $OutDir "_stage"
$bundleDir = Join-Path $stageDir $BundleName
$bundleWinDir = Join-Path $bundleDir "win"

if (Test-Path $bundleDir) {
    Remove-Item -Path $bundleDir -Recurse -Force
}
New-Item -Path $bundleWinDir -ItemType Directory -Force | Out-Null

Copy-Item -Path (Join-Path $SourceRoot "xui11.sh.fixed.sh") -Destination (Join-Path $bundleDir "xui11.sh.fixed.sh") -Force

$topAssetPatterns = @("*.png", "*.mp3", "*.mp4", "*.webp", "*.jpg", "*.jpeg", "*.gif", "*.svg", "*.wav")
foreach ($pat in $topAssetPatterns) {
    Get-ChildItem -Path $SourceRoot -Filter $pat -File -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $bundleDir -Force
    }
}

foreach ($dirName in @("assets", "user_sounds")) {
    $srcDir = Join-Path $SourceRoot $dirName
    $dstDir = Join-Path $bundleDir $dirName
    if (Test-Path $srcDir) {
        Copy-Item -Path $srcDir -Destination $dstDir -Recurse -Force
    }
}

$winFiles = @(
    "install_xui_windows.ps1",
    "install_xui_windows.bat",
    "xui_start_windows.bat",
    "xui_update_check.py",
    "extract_xui_payload.py",
    "README.md",
    "build_win.ps1",
    "build_win.bat"
)
foreach ($f in $winFiles) {
    $src = Join-Path $PSScriptRoot $f
    if (-not (Test-Path $src)) {
        throw "Missing win file: $src"
    }
    Copy-Item -Path $src -Destination (Join-Path $bundleWinDir $f) -Force
}

$rootInstallBat = Join-Path $bundleDir "install_xui_windows.bat"
@'
@echo off
setlocal
call "%~dp0win\install_xui_windows.bat" %*
'@ | Set-Content -Path $rootInstallBat -Encoding ASCII

$rootReadme = Join-Path $bundleDir "README-WINDOWS.txt"
@'
XUI Windows Bundle
==================

1) Install Python 3.10+ (Add to PATH).
2) Run install_xui_windows.bat (in this folder).
3) After installation, launch %USERPROFILE%\.xui\bin\xui_start.bat
'@ | Set-Content -Path $rootReadme -Encoding ASCII

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$zipPath = Join-Path $OutDir "$BundleName-$timestamp.zip"
if (Test-Path $zipPath) {
    Remove-Item -Path $zipPath -Force
}

Compress-Archive -Path $bundleDir -DestinationPath $zipPath -CompressionLevel Optimal -Force
Write-Host "[DONE] Bundle created: $zipPath"

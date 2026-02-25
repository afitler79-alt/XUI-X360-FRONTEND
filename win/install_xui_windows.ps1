Param(
    [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$XuiHome = "$HOME\.xui",
    [string]$UpdateBranch = "Windows",
    [switch]$EnableAutostart,
    [switch]$SkipPip
)

$ErrorActionPreference = "Stop"

function Invoke-Python {
    param([string[]]$Args)
    if (-not $script:PyLauncher) {
        $script:PyLauncher = ""
        $tests = @(
            @{cmd = "py";      args = @("-3", "-V")},
            @{cmd = "python";  args = @("--version")},
            @{cmd = "python3"; args = @("--version")}
        )
        foreach ($t in $tests) {
            $cmd = [string]$t.cmd
            if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
                continue
            }
            try {
                & $cmd @($t.args) *> $null
                $rc = $LASTEXITCODE
                if ($null -eq $rc) { $rc = 0 }
                if ([int]$rc -eq 0) {
                    $script:PyLauncher = $cmd
                    break
                }
            } catch {
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($script:PyLauncher)) {
        throw "Python 3 not available. Install Python 3.10+ (python.org), enable Add to PATH, or disable Windows App Execution Alias for python/python3."
    }

    if ($script:PyLauncher -eq "py") {
        & py -3 @Args
    } else {
        & $script:PyLauncher @Args
    }
    return $LASTEXITCODE
}

Write-Host "[INFO] XUI Windows installer"
Write-Host "[INFO] SourceRoot: $SourceRoot"
Write-Host "[INFO] XuiHome: $XuiHome"

function Resolve-SourceInstallerPath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseRoot,
        [string]$Branch = "Windows"
    )

    $candidatePaths = @(
        (Join-Path $BaseRoot "xui11.sh.fixed.sh"),
        (Join-Path (Join-Path $PSScriptRoot "..") "xui11.sh.fixed.sh"),
        (Join-Path (Join-Path $PSScriptRoot "..\..") "xui11.sh.fixed.sh"),
        (Join-Path (Join-Path $PSScriptRoot "..\dist") "xui11.sh.fixed.sh")
    )
    foreach ($p in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path $p -PathType Leaf)) {
            return (Resolve-Path $p).Path
        }
    }

    try {
        $near = Get-ChildItem -Path $BaseRoot -Filter "xui11.sh.fixed.sh" -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($near -and (Test-Path $near.FullName -PathType Leaf)) {
            return $near.FullName
        }
    } catch {
    }

    $branches = @($Branch, "Windows", "Main-XUI", "main")
    $cacheDir = Join-Path $env:TEMP "xui-win-installer-cache"
    New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
    foreach ($b in $branches) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        $url = "https://raw.githubusercontent.com/afitler79-alt/XUI-X360-FRONTEND/$b/xui11.sh.fixed.sh"
        $dst = Join-Path $cacheDir ("xui11.sh.fixed." + $b + ".sh")
        try {
            Invoke-WebRequest -Uri $url -OutFile $dst -TimeoutSec 30 -ErrorAction Stop
            if ((Test-Path $dst -PathType Leaf) -and ((Get-Item $dst).Length -gt 4096)) {
                Write-Host "[INFO] Downloaded source installer from branch: $b"
                return $dst
            }
        } catch {
        }
    }

    return ""
}

$xuiAssets = Join-Path $XuiHome "assets"
$xuiBin = Join-Path $XuiHome "bin"
$xuiDash = Join-Path $XuiHome "dashboard"
$xuiData = Join-Path $XuiHome "data"
$xuiGames = Join-Path $XuiHome "games"
$xuiLogs = Join-Path $XuiHome "logs"

@($XuiHome, $xuiAssets, $xuiBin, $xuiDash, $xuiData, $xuiGames, $xuiLogs) | ForEach-Object {
    New-Item -Path $_ -ItemType Directory -Force | Out-Null
}

$sourceScript = Resolve-SourceInstallerPath -BaseRoot $SourceRoot -Branch $UpdateBranch
if ([string]::IsNullOrWhiteSpace($sourceScript) -or (-not (Test-Path $sourceScript -PathType Leaf))) {
    throw "Source installer not found. Looked in: $SourceRoot and nearby bundle folders. Expected xui11.sh.fixed.sh"
}
$resolvedSourceRoot = (Split-Path -Parent $sourceScript)
Write-Host "[INFO] SourceScript: $sourceScript"

$extractPy = Join-Path $PSScriptRoot "extract_xui_payload.py"
if (-not (Test-Path $extractPy)) {
    throw "Extractor not found: $extractPy"
}

$payloadDir = Join-Path $PSScriptRoot "payload"
if (Test-Path $payloadDir) {
    Remove-Item -Path $payloadDir -Recurse -Force
}
New-Item -Path $payloadDir -ItemType Directory -Force | Out-Null

Write-Host "[INFO] Extracting payload from master installer..."
$rc = Invoke-Python @($extractPy, "--source", $sourceScript, "--out", $payloadDir)
if ($rc -ne 0) {
    if ($rc -eq 9009) {
        throw "Payload extraction failed (9009): Python launcher not executable. Install Python 3.10+ from python.org or disable App Execution Alias for python/python3."
    }
    throw "Payload extraction failed with code $rc"
}

$fileMap = @{
    "pyqt_dashboard_improved.py" = (Join-Path $xuiDash "pyqt_dashboard_improved.py")
    "xui_webhub.py" = (Join-Path $xuiBin "xui_webhub.py")
    "xui_social_chat.py" = (Join-Path $xuiBin "xui_social_chat.py")
    "xui_store_modern.py" = (Join-Path $xuiBin "xui_store_modern.py")
    "xui_global_guide.py" = (Join-Path $xuiBin "xui_global_guide.py")
    "xui_first_setup.py" = (Join-Path $xuiBin "xui_first_setup.py")
    "xui_game_lib.py" = (Join-Path $xuiBin "xui_game_lib.py")
    "xui_web_api.py" = (Join-Path $xuiBin "xui_web_api.py")
}

foreach ($name in $fileMap.Keys) {
    $src = Join-Path $payloadDir $name
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $fileMap[$name] -Force
        Write-Host "[OK] $name"
    }
}

$updateCheckerSrc = Join-Path $PSScriptRoot "xui_update_check.py"
$updateCheckerDst = Join-Path $xuiBin "xui_update_check.py"
if (Test-Path $updateCheckerSrc) {
    Copy-Item -Path $updateCheckerSrc -Destination $updateCheckerDst -Force
    Write-Host "[OK] xui_update_check.py"
}

$assetSources = @(
    $resolvedSourceRoot,
    $SourceRoot,
    (Join-Path $resolvedSourceRoot "assets"),
    (Join-Path $resolvedSourceRoot "user_sounds"),
    (Join-Path $SourceRoot "assets"),
    (Join-Path $SourceRoot "user_sounds")
)
$assetPatterns = @("*.png", "*.mp3", "*.mp4", "*.webp", "*.jpg", "*.jpeg", "*.gif", "*.svg", "*.wav")
foreach ($srcDir in $assetSources) {
    if (-not (Test-Path $srcDir)) {
        continue
    }
    foreach ($pat in $assetPatterns) {
        Get-ChildItem -Path $srcDir -Filter $pat -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $xuiAssets -Force
        }
    }
}
Write-Host "[INFO] Assets synced to $xuiAssets"

$launcherTemplate = Join-Path $PSScriptRoot "xui_start_windows.bat"
$launcherDest = Join-Path $xuiBin "xui_start.bat"
if (Test-Path $launcherTemplate) {
    Copy-Item -Path $launcherTemplate -Destination $launcherDest -Force
} else {
    "@echo off`r`npy -3 `"%USERPROFILE%\.xui\dashboard\pyqt_dashboard_improved.py`"" | Set-Content -Path $launcherDest -Encoding ASCII
}
Write-Host "[INFO] Launcher: $launcherDest"

if ([string]::IsNullOrWhiteSpace($UpdateBranch)) {
    $UpdateBranch = "Windows"
}
$channelPath = Join-Path $xuiData "update_channel.json"
$channelData = @{
    platform = "windows"
    branch = "$UpdateBranch"
    repo = "afitler79-alt/XUI-X360-FRONTEND"
    source_dir = "$resolvedSourceRoot"
    updated_at_epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}
$channelData | ConvertTo-Json -Depth 4 | Set-Content -Path $channelPath -Encoding UTF8
Write-Host "[INFO] Update channel configured: $UpdateBranch"

if (-not $SkipPip) {
    Write-Host "[INFO] Installing Python dependencies..."
    $rc = Invoke-Python @("-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel")
    if ($rc -ne 0) { Write-Warning "pip bootstrap failed ($rc)" }
    $rc = Invoke-Python @("-m", "pip", "install", "PyQt5", "PyQtWebEngine", "Pillow", "pygame", "requests", "psutil")
    if ($rc -ne 0) { Write-Warning "some Python deps could not be installed ($rc)" }
}

try {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $shortcutPath = Join-Path $desktop "XUI Dashboard.lnk"
    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $launcherDest
    $shortcut.WorkingDirectory = $xuiBin
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,220"
    $shortcut.Save()
    Write-Host "[INFO] Desktop shortcut created: $shortcutPath"
} catch {
    Write-Warning "Could not create desktop shortcut: $($_.Exception.Message)"
}

if ($EnableAutostart) {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    New-ItemProperty -Path $runKey -Name "XUI-Dashboard" -Value "`"$launcherDest`"" -PropertyType String -Force | Out-Null
    Write-Host "[INFO] Autostart enabled."
}

Write-Host ""
Write-Host "[DONE] XUI Windows integration installed."
Write-Host "Run: $launcherDest"

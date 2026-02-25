[CmdletBinding()]
param(
    [switch]$YesInstall
)

$ErrorActionPreference = "Stop"

function Write-Info($m){ Write-Host "[INFO] $m" }
function Write-Warn($m){ Write-Warning $m }

$UserHome = $env:USERPROFILE
if (-not $UserHome) { $UserHome = [Environment]::GetFolderPath("UserProfile") }
$XuiDir = Join-Path $UserHome ".xui"
$AssetsDir = Join-Path $XuiDir "assets"
$BinDir = Join-Path $XuiDir "bin"
$DashboardDir = Join-Path $XuiDir "dashboard"
$DataDir = Join-Path $XuiDir "data"
$LogsDir = Join-Path $XuiDir "logs"

function Ensure-Dirs(){
    foreach($d in @($XuiDir,$AssetsDir,$BinDir,$DashboardDir,$DataDir,$LogsDir)){
        if(-not (Test-Path $d)){ New-Item -ItemType Directory -Path $d | Out-Null }
    }
}

function Resolve-Python(){
    $candidates=@("py","python3","python")
    foreach($c in $candidates){
        $cmd=Get-Command $c -ErrorAction SilentlyContinue
        if($cmd){ return $cmd.Path }
    }
    return $null
}

function Invoke-PythonScript($py,$code){
    $tmp=[System.IO.Path]::GetTempFileName()
    Set-Content -Path $tmp -Value $code -Encoding UTF8
    try { & $py $tmp } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

function Install-Dependencies($py){
    if(-not $YesInstall){ Write-Info "Omitiendo instalación de dependencias (use --yes-install)"; return }
    try { & $py -m pip install --user PyQt5 Pillow | Out-Null }
    catch { Write-Warn "pip falló: $($_.Exception.Message)" }
}

function Copy-Assets(){
    $sources=@($PSScriptRoot, (Split-Path -Parent $PSScriptRoot))
    foreach($src in $sources){
        if(-not $src -or -not (Test-Path $src)){ continue }
        Get-ChildItem -Path $src -File -Include *.png,*.jpg,*.jpeg,*.webp,*.mp3,*.mp4 | ForEach-Object {
            $dest = Join-Path $AssetsDir $_.Name
            Copy-Item $_.FullName $dest -Force
        }
    }
}

function Generate-Placeholders($py){
    if(-not $py){ return }
    $code = @'
from pathlib import Path
try:
    from PIL import Image, ImageDraw, ImageFont
except Exception:
    Image = None
AS = Path.home()/'.xui'/'assets'
AS.mkdir(parents=True, exist_ok=True)
if Image is None:
    raise SystemExit(0)

def make_img(fn, size=(320,180), text='XUI'):
    p = AS/fn
    if p.exists():
        return
    im = Image.new('RGBA', size, (12,84,166,255))
    d = ImageDraw.Draw(im)
    try:
        f = ImageFont.truetype('arial.ttf', max(24, size[1]//6))
    except Exception:
        f = ImageFont.load_default()
    w,h = d.textsize(text, font=f)
    d.text(((size[0]-w)/2,(size[1]-h)/2), text, fill=(255,255,255,255), font=f)
    im.save(p)

make_img('applogo.png', (512,512), 'XUI')
make_img('bootlogo.png', (800,450), 'XUI')
for t in ['Casino','Runner','Store','Misiones','Perfil','Compat X86','LAN','Power Profile','Battery Saver','Salir al escritorio']:
    make_img(f"{t}.png", (320,180), t)
'@
    try { Invoke-PythonScript $py $code } catch { Write-Warn "Placeholders no generados: $($_.Exception.Message)" }
}

function Convert-PngToWebp($py){
    if(-not $py){ return }
    $code = @'
from pathlib import Path
try:
    from PIL import Image
except Exception:
    Image = None
ad = Path.home()/'.xui'/'assets'
if Image is None:
    raise SystemExit(0)
for p in ad.glob('*.png'):
    try:
        img = Image.open(p)
        img.save(p.with_suffix('.webp'), 'WEBP', quality=80)
    except Exception:
        pass
'@
    try { Invoke-PythonScript $py $code } catch { Write-Warn "WEBP no generado: $($_.Exception.Message)" }
}

function Write-Manifest(){
    $files = Get-ChildItem -Path $AssetsDir -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -ExpandProperty Name
    $manifest = @{ assets = $files }
    $json = $manifest | ConvertTo-Json -Depth 2
    Set-Content -Path (Join-Path $AssetsDir "manifest.json") -Value $json -Encoding UTF8
}

function Copy-Dashboard(){
    $candidate = Join-Path $PSScriptRoot "pyqt_dashboard_improved.py"
    if(-not (Test-Path $candidate)){
        $candidate = Join-Path (Split-Path -Parent $PSScriptRoot) "pyqt_dashboard_improved_fixed2.py"
    }
    $target = Join-Path $DashboardDir "pyqt_dashboard_improved.py"
    if(Test-Path $candidate){ Copy-Item $candidate $target -Force; return }
    $fallback = @'
import sys
try:
    from PyQt5 import QtWidgets
except Exception:
    sys.exit(1)
app = QtWidgets.QApplication([])
win = QtWidgets.QWidget()
win.setWindowTitle("XUI Dashboard")
QtWidgets.QLabel("XUI", parent=win)
win.show()
sys.exit(app.exec_())
'@
    Set-Content -Path $target -Value $fallback -Encoding UTF8
}

function Write-UpdateChecker(){
    $repo = $env:XUI_UPDATE_REPO
    if(-not $repo){ $repo = "afitler79-alt/XUI-X360-FRONTEND" }
    $srcDefault = Join-Path $DataDir "src/XUI-X360-FRONTEND"
    $checker = @"
param(
    [string]
    `$Mode = "status",
    [switch]`$Json
)
`$ErrorActionPreference = "Stop"
`$repo = "$repo"
`$stateFile = Join-Path "$DataDir" "update_state.json"
`$srcDir = `$env:XUI_SOURCE_DIR
if(-not `$srcDir -or `$srcDir -eq ''){ `$srcDir = "$srcDefault" }
`$installerName = `$env:XUI_UPDATE_INSTALLER
if(-not `$installerName -or `$installerName -eq ''){ `$installerName = "xui/win/xui11.ps1" }

function Read-State(){
    if(-not (Test-Path `$stateFile)){ return @{} }
    try { return Get-Content `$stateFile -Raw | ConvertFrom-Json } catch { return @{} }
}

function Write-State(`$commit,`$branch,`$date,`$src){
    `$obj = [pscustomobject]@{
        installed_commit = `$commit
        branch = `$branch
        remote_date = `$date
        installed_at_epoch = [int][double]::Parse((Get-Date -UFormat %s))
        source_dir = `$src
        version = 2
    }
    New-Item -ItemType Directory -Path (Split-Path `$stateFile) -Force | Out-Null
    `$obj | ConvertTo-Json -Depth 4 | Set-Content -Path `$stateFile -Encoding UTF8
}

function Fetch-RepoMeta(){
    `$headers = @{ "Accept"="application/vnd.github+json"; "User-Agent"="xui-update-checker" }
    `$info = Invoke-RestMethod -Uri "https://api.github.com/repos/`$repo" -Headers `$headers -TimeoutSec 12
    `$branch = `$info.default_branch
    if(-not `$branch){ `$branch = "main" }
    `$commit = Invoke-RestMethod -Uri "https://api.github.com/repos/`$repo/commits/`$branch" -Headers `$headers -TimeoutSec 12
    [pscustomobject]@{
        branch = `$branch
        remote_commit = `$commit.sha
        remote_date = `$commit.commit.committer.date
        remote_url = `$commit.html_url
    }
}

function Get-Status(){
    `$state = Read-State()
    `$meta = $null
    try { `$meta = Fetch-RepoMeta() } catch { `$meta = $null }
    `$local = ""; if(`$state){ `$local = [string]`$state.installed_commit }
    `$checked = ($meta -ne $null)
    `$required = $true
    `$reason = "missing-local-version"
    `$branch = "main"; `$remote_commit = ""; `$remote_date = ""; `$remote_url = ""
    if(`$meta){
        `$branch = [string]`$meta.branch
        `$remote_commit = [string]`$meta.remote_commit
        `$remote_date = [string]`$meta.remote_date
        `$remote_url = [string]`$meta.remote_url
        if(-not `$remote_commit){ `$required = $true; `$reason = "missing-remote-sha" }
        elseif(-not `$local){ `$required = $true; `$reason = "missing-local-version" }
        elseif(`$local -ne `$remote_commit){ `$required = $true; `$reason = "outdated" }
        else { `$required = $false; `$reason = "up-to-date" }
    } else {
        `$required = $false
        `$reason = "remote-unavailable"
    }
    [pscustomobject]@{
        checked = `$checked
        mandatory = $true
        update_required = `$required
        reason = `$reason
        repo = `$repo
        branch = `$branch
        local_commit = `$local
        remote_commit = `$remote_commit
        remote_date = `$remote_date
        remote_url = `$remote_url
    }
}

function Ensure-Git(){
    `$g = Get-Command git -ErrorAction SilentlyContinue
    if(`$g){ return `$g.Path }
    return $null
}

function Download-Zip(`$url,`$destZip,`$destDir){
    Invoke-WebRequest -Uri `$url -OutFile `$destZip -UseBasicParsing
    if(Test-Path `$destDir){ Remove-Item -Recurse -Force `$destDir }
    Expand-Archive -Path `$destZip -DestinationPath (Split-Path `$destDir) -Force
    `$folder = Get-ChildItem -Path (Split-Path `$destDir) -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if(-not `$folder){ throw "ZIP expand failed" }
    Move-Item -Path `$folder.FullName -Destination `$destDir -Force
}

function Apply-Update(){
    `$meta = Fetch-RepoMeta()
    if(-not `$meta){ throw "No remote metadata" }
    `$branch = `$meta.branch; if(-not `$branch){ `$branch = "main" }
    `$remote_commit = `$meta.remote_commit
    `$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("xui_update_" + [System.Guid]::NewGuid().ToString())
    `$tmpZip = "$tmp.zip"
    `$git = Ensure-Git()
    if(-not (Test-Path `$srcDir)){ New-Item -ItemType Directory -Path `$srcDir -Force | Out-Null }
    if($git){
        if(-not (Test-Path (Join-Path `$srcDir ".git"))){
            git clone "https://github.com/`$repo.git" `$srcDir
        } else {
            git -C `$srcDir fetch --all --prune
        }
        git -C `$srcDir checkout -B `$branch "origin/`$branch" | Out-Null
        git -C `$srcDir reset --hard "origin/`$branch" | Out-Null
        git -C `$srcDir clean -fd | Out-Null
    } else {
        `$zipUrl = "https://github.com/`$repo/archive/refs/heads/`$branch.zip"
        Download-Zip `$zipUrl `$tmpZip `$tmp
        if(Test-Path `$srcDir){ Remove-Item -Recurse -Force `$srcDir }
        Move-Item -Path `$tmp -Destination `$srcDir -Force
    }
    `$installer = Join-Path `$srcDir `$installerName
    if(-not (Test-Path `$installer)){
        throw "Installer not found: `$installer"
    }
    powershell -ExecutionPolicy Bypass -File `$installer -YesInstall
    Write-State `$remote_commit `$branch `$meta.remote_date `$srcDir
}

switch($Mode){
    "mandatory" {
        `$s = Get-Status()
        if(`$Json){ `$s | ConvertTo-Json -Depth 4; exit 0 }
        if(`$s.update_required){ Write-Host "Update required"; exit 10 }
        Write-Host "Up to date"; exit 0
    }
    "apply" {
        try { Apply-Update(); if(`$Json){ @{status="ok"}|ConvertTo-Json }; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }
    }
    default {
        `$s = Get-Status(); if(`$Json){ `$s | ConvertTo-Json -Depth 4 } else { `$s } | Out-Host; if(`$s.update_required){ exit 10 } else { exit 0 }
    }
}
"@
    Set-Content -Path (Join-Path $BinDir "xui_update_check.ps1") -Value $checker -Encoding UTF8
}

function Write-Launchers($py){
    $dash = Join-Path $DashboardDir "pyqt_dashboard_improved.py"
    $upd = Join-Path $BinDir "xui_update_check.ps1"
    $launcher = @"
`$ErrorActionPreference="Stop"
`$upd = "$upd"
`$py = "$py"
`$script = "$dash"
if(Test-Path `$upd){
    try{
        `$res = & `$upd mandatory -Json | ConvertFrom-Json
        if(`$res.update_required -eq $true){
            & `$upd apply
        }
    } catch {
        Write-Host "[WARN] update check failed: $($_.Exception.Message)"
    }
}
& `$py "`$script"
"@
    Set-Content -Path (Join-Path $BinDir "xui_start.ps1") -Value $launcher -Encoding UTF8
    $cmd = "@echo off`r`npowershell -ExecutionPolicy Bypass -File `"$($BinDir)\xui_start.ps1`"`r`n"
    Set-Content -Path (Join-Path $BinDir "xui_start.cmd") -Value $cmd -Encoding ASCII
    $uninstaller = @"
param([switch]`$Confirm)
`$target = "$XuiDir"
if(-not `$Confirm){
    Write-Host "Run with -Confirm to delete `$target"
    exit 0
}
if(Test-Path `$target){
    Remove-Item -Recurse -Force `$target
    Write-Host "Removed `$target"
}
"@
    Set-Content -Path (Join-Path $BinDir "xui_uninstall.ps1") -Value $uninstaller -Encoding UTF8
}

function Smoke-Test($py){
    if(-not $py){ return }
    $code = "from PyQt5 import QtWidgets; import sys; app=QtWidgets.QApplication([]); sys.exit(0)"
    try { & $py -c $code | Out-Null } catch { Write-Warn "PyQt5 no responde: $($_.Exception.Message)" }
}

function Main(){
    Write-Info "Instalando XUI en $XuiDir"
    Ensure-Dirs
    Copy-Assets
    $py = Resolve-Python
    if(-not $py){ Write-Warn "Python 3 no encontrado" }
    Install-Dependencies $py
    Generate-Placeholders $py
    Convert-PngToWebp $py
    Write-Manifest
    Copy-Dashboard
    Write-UpdateChecker
    if($py){ Write-Launchers $py }
    Smoke-Test $py
    Write-Info "Listo. Ejecuta $BinDir\\xui_start.ps1"
}

Main

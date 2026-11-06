param(
    [switch]$ResetAccounts
)

$ErrorActionPreference = "Stop"
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = Join-Path $env:LOCALAPPDATA "antigravity-fork"
$VenvDir = Join-Path $InstallDir ".venv"
$ToolsDataDir = Join-Path $env:USERPROFILE ".antigravity_tools"
$AgyCfgDir = Join-Path $env:USERPROFILE ".config\agy-backends"
$AgyStateDir = Join-Path $env:USERPROFILE ".local\state\agy-backends"
$AgyCliDir = Join-Path $env:USERPROFILE ".gemini\antigravity-cli"
$StartupDir = [Environment]::GetFolderPath("Startup")

New-Item -ItemType Directory -Force -Path $InstallDir, "$ToolsDataDir\accounts", $AgyCfgDir, $AgyStateDir, $AgyCliDir | Out-Null

Write-Host "[1/6] Stopping any previous instances..."
Get-Process -Name "antigravity-tools" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name LIKE 'python%' AND CommandLine LIKE '%gateway:app%'" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host "[2/6] Preparing patched antigravity-tools.exe..."
$TargetExe = Join-Path $InstallDir "antigravity-tools.exe"
$LocalBuiltExe = Join-Path $RepoDir "antigravity-tools.exe"
$ReleaseUrl = "https://github.com/mqrkin/antigravity-token-fork/releases/latest/download/antigravity-tools.exe"

if (Test-Path $LocalBuiltExe) {
    Copy-Item -Force $LocalBuiltExe $TargetExe
} else {
    $Downloaded = $false
    try {
        Write-Host "Attempting to download prebuilt antigravity-tools.exe from GitHub Release..."
        Invoke-WebRequest -Uri $ReleaseUrl -OutFile $TargetExe -UseBasicParsing -TimeoutSec 60
        if ((Get-Item $TargetExe).Length -gt 1000000) {
            $Downloaded = $true
            Write-Host "Downloaded prebuilt antigravity-tools.exe."
        }
    } catch {
        Write-Host "Prebuilt release binary not available yet, building from patched source..."
    }

    if (-not $Downloaded) {
        if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
            Write-Host "Installing Rust toolchain via winget..."
            winget install --id Rustlang.Rustup -e --silent --accept-package-agreements --accept-source-agreements
            $env:PATH = "$env:USERPROFILE\.cargo\bin;$env:PATH"
        }
        Push-Location $RepoDir
        try {
            cargo build --release --manifest-path src-tauri/Cargo.toml --bin antigravity-tools
            if ($LASTEXITCODE -ne 0) { throw "Building antigravity-tools.exe failed." }
            Copy-Item -Force "src-tauri\target\release\antigravity-tools.exe" $TargetExe
        } finally {
            Pop-Location
        }
    }
}

Write-Host "[3/6] Installing gateway.py, login.py, and Python environment..."
Copy-Item -Force (Join-Path $RepoDir "gateway\gateway.py") (Join-Path $InstallDir "gateway.py")
Copy-Item -Force (Join-Path $RepoDir "login.py") (Join-Path $InstallDir "login.py")

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Python 3.12 via winget..."
    winget install --id Python.Python.3.12 -e --silent --accept-package-agreements --accept-source-agreements
}

$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
if (-not (Test-Path $VenvPython)) {
    python -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { throw "Creating the Python environment failed." }
}
& $VenvPython -m pip install --quiet --upgrade pip fastapi uvicorn httpx
if ($LASTEXITCODE -ne 0) { throw "Installing Python dependencies failed." }

Write-Host "[4/6] Generating clean local configuration (zero third-party accounts)..."
if ($ResetAccounts) {
    Remove-Item -Recurse -Force "$ToolsDataDir\accounts\*" -ErrorAction SilentlyContinue
    Remove-Item -Force "$ToolsDataDir\accounts.json" -ErrorAction SilentlyContinue
}

$InitScript = @'
import json, pathlib, re, secrets, sys

tools_dir = pathlib.Path(sys.argv[1])
agy_cfg_dir = pathlib.Path(sys.argv[2])
agy_state_dir = pathlib.Path(sys.argv[3])
agy_cli_dir = pathlib.Path(sys.argv[4])

def read_object(path):
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        text = re.sub(r'("(?:\\.|[^"\\])*")|//[^\n]*|/\*[\s\S]*?\*/',
                      lambda match: match.group(1) or '', text)
        text = re.sub(r'("(?:\\.|[^"\\])*")|,\s*([}\]])',
                      lambda match: match.group(1) or match.group(2), text)
        value = json.loads(text)
    if not isinstance(value, dict):
        raise ValueError(f"Expected an object in {path}")
    return value

gui_cfg_path = tools_dir / "gui_config.json"
gw_cfg_path = agy_cfg_dir / "gateway.json"
settings_path = agy_cli_dir / "settings.json"
gui_cfg = read_object(gui_cfg_path)
gw_cfg = read_object(gw_cfg_path)
settings = read_object(settings_path)

for key, value in {
    "language": "en", "theme": "system", "auto_refresh": True,
    "refresh_interval": 15, "auto_sync": False, "sync_interval": 5,
}.items():
    gui_cfg.setdefault(key, value)

proxy_cfg = gui_cfg.setdefault("proxy", {})
proxy_key = proxy_cfg.get("api_key") or ("sk-ag-proxy-" + secrets.token_hex(16))
proxy_cfg.update({
    "enabled": True,
    "allow_lan_access": False,
    "auth_mode": "all_except_health",
    "port": 8045,
    "api_key": proxy_key,
    "auto_start": True,
    "request_timeout": 300,
    "enable_logging": True,
})
proxy_cfg.setdefault("custom_mapping", {})["internal-background-task"] = "gemini-3.1-flash-lite"
proxy_cfg.setdefault("multimodal", {}).update({"enable_sliding_window": True, "max_fresh_images": 6})
gui_cfg_path.write_text(json.dumps(gui_cfg, indent=2) + "\n", encoding="utf-8")

(tools_dir / "update_settings.json").write_text(json.dumps({
    "auto_check": False,
    "auto_install": False,
    "last_check_time": 0,
    "check_interval_hours": 87600,
    "skipped_version": "99.99.99"
}, indent=2) + "\n", encoding="utf-8")

accounts_index = tools_dir / "accounts.json"
if not accounts_index.exists():
    accounts_index.write_text(json.dumps({"accounts": [], "current_account_id": None}, indent=2) + "\n", encoding="utf-8")

gw_key = gw_cfg.get("apiKey") or gw_cfg.get("api_key") or ("sk-ag-gw-" + secrets.token_hex(24))
gw_cfg.update({
    "apiKey": gw_key,
    "proxy": {
        "base_url": "http://127.0.0.1:8045",
        "api_key": proxy_key,
        "model": "gemini-4-argon-medium"
    }
})
gw_cfg.pop("api_key", None)
gw_cfg_path.write_text(json.dumps(gw_cfg, indent=2) + "\n", encoding="utf-8")

(agy_cfg_dir / "selection.json").write_text(json.dumps({"mode": "proxy"}, indent=2) + "\n", encoding="utf-8")
(agy_state_dir / "route.json").write_text(json.dumps({"mode": "proxy"}, indent=2) + "\n", encoding="utf-8")

client_data = {
    "apiKey": gw_key,
    "endpoint": "http://127.0.0.1:5919",
}
(agy_cfg_dir / "client.json").write_text(json.dumps(client_data, indent=2) + "\n", encoding="utf-8")

settings["model"] = "Gemini 4 Argon (Medium)"
settings["modelProvider"] = "gemini"
settings.setdefault("customModelsConfig", {}).setdefault("customModels", {})["agy-current"] = {
    "modelId": "agy-current", "modelName": "gemini-api://agy-current",
    "label": "Gemini 4 Argon (Medium)", "apiProvider": "API_PROVIDER_GOOGLE_GEMINI",
    "maxTokens": 131072,
    "modelFeatures": {"supportsImages": True, "supportsAudio": True, "supportsPdf": True,
                      "supportsVideo": True, "supportsToolCalls": True,
                      "supportsThinking": True, "zeroShotCapable": True},
}
settings_path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
'@

$InitPyPath = Join-Path $InstallDir "init_config.py"
Set-Content -Path $InitPyPath -Value $InitScript -Encoding UTF8
& $VenvPython $InitPyPath $ToolsDataDir $AgyCfgDir $AgyStateDir $AgyCliDir
if ($LASTEXITCODE -ne 0) { throw "Preparing the local configuration failed." }

Write-Host "[5/6] Configuring headless auto-restart watchdog and Windows Startup..."
$RunnerPs1 = Join-Path $InstallDir "run-watchdog.ps1"
$RunnerContent = @"
`$env:ANTIGRAVITY_DISABLE_TRAY = "1"
`$env:ANTIGRAVITY_HEADER_TIMEOUT_SECS = "35"
`$env:ANTIGRAVITY_SANDBOX_FIRST_BYTES = "0"
`$env:ABV_BIND_LOCAL_ONLY = "1"
`$InstallDir = "$InstallDir"
`$TargetExe = "$TargetExe"
`$VenvPython = "$VenvPython"

while (`$true) {
    if (-not (Get-Process -Name "antigravity-tools" -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath `$TargetExe -ArgumentList "--headless" -WorkingDirectory `$InstallDir -WindowStyle Hidden
    }
    `$gw = Get-CimInstance Win32_Process -Filter "Name LIKE 'python%' AND CommandLine LIKE '%gateway:app%'" -ErrorAction SilentlyContinue
    if (-not `$gw) {
        Start-Process -FilePath `$VenvPython -ArgumentList "-m uvicorn gateway:app --host 127.0.0.1 --port 5919 --no-access-log --timeout-graceful-shutdown 5" -WorkingDirectory `$InstallDir -WindowStyle Hidden
    }
    Start-Sleep -Seconds 3
}
"@
Set-Content -Path $RunnerPs1 -Value $RunnerContent -Encoding UTF8

$VbsPath = Join-Path $StartupDir "antigravity-fork-headless.vbs"
$VbsContent = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$RunnerPs1""", 0, False
"@
Set-Content -Path $VbsPath -Value $VbsContent -Encoding ASCII

Start-Process -FilePath "wscript.exe" -ArgumentList "`"$VbsPath`"" -WindowStyle Hidden

Write-Host "[6/6] Waiting for the gateway and Tools proxy ..."
$GatewayReady = $false
$ProxyReady = $false
for ($i = 0; $i -lt 30; $i++) {
    $GatewayReady = $false
    $ProxyReady = $false
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:5919/health" -UseBasicParsing -TimeoutSec 2
        if ($resp.StatusCode -eq 200) {
            $GatewayReady = $true
        }
    } catch {}
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:8045/health" -UseBasicParsing -TimeoutSec 2
        if ($resp.StatusCode -eq 200) { $ProxyReady = $true }
    } catch {}
    if ($GatewayReady -and $ProxyReady) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $GatewayReady -or -not $ProxyReady) {
    throw "The gateway or Tools proxy failed to start."
}

Write-Host "Installation complete! Starting Google OAuth login for your account..."
& $VenvPython (Join-Path $InstallDir "login.py") --wait
if ($LASTEXITCODE -ne 0) { throw "Google sign-in did not complete." }

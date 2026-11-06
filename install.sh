#!/usr/bin/env bash
set -euo pipefail
umask 077

DIST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPT_DIR="$HOME/.local/opt/antigravity-tools"
BACKEND_DIR="$HOME/.local/share/agy-backends"
VENV_DIR="$BACKEND_DIR/.venv"
TOOLS_DATA_DIR="$HOME/.antigravity_tools"
AGY_CFG_DIR="$HOME/.config/agy-backends"
AGY_STATE_DIR="$HOME/.local/state/agy-backends"
AGY_CLI_DIR="$HOME/.gemini/antigravity-cli"
SYSTEMD_DIR="$HOME/.config/systemd/user"

echo "[1/6] Installing patched Antigravity Tools runtime to $OPT_DIR..."
mkdir -p "$OPT_DIR" "$HOME/.local/bin"
cp -a --remove-destination "$DIST_DIR/runtime/." "$OPT_DIR/"
chmod +x "$OPT_DIR/AppRun" "$OPT_DIR/AppRun.wrapped" "$OPT_DIR/usr/bin/antigravity-tools"

cat > "$HOME/.local/bin/antigravity-tools" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export ANTIGRAVITY_HEADER_TIMEOUT_SECS=35
export ANTIGRAVITY_SANDBOX_FIRST_BYTES=0
export ABV_BIND_LOCAL_ONLY=1
exec "$OPT_DIR/AppRun" "\$@"
EOF
chmod +x "$HOME/.local/bin/antigravity-tools"

echo "[2/6] Installing token-efficient gateway to $BACKEND_DIR..."
mkdir -p "$BACKEND_DIR"
cp -a "$DIST_DIR/gateway/gateway.py" "$BACKEND_DIR/gateway.py"
cp -a "$DIST_DIR/login.py" "$BACKEND_DIR/login.py"
chmod +x "$BACKEND_DIR/login.py"

if [ ! -x "$VENV_DIR/bin/python" ]; then
  python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install --quiet --upgrade pip fastapi "uvicorn[standard]" httpx

echo "[3/6] Generating clean local configuration (no third-party accounts)..."
mkdir -p "$TOOLS_DATA_DIR/accounts" "$AGY_CFG_DIR" "$AGY_STATE_DIR" "$AGY_CLI_DIR"
chmod 700 "$AGY_CFG_DIR"

if [ "${1:-}" = "--reset-accounts" ]; then
  rm -rf "$TOOLS_DATA_DIR/accounts"/*
  rm -f "$TOOLS_DATA_DIR/accounts.json"
fi

python3 - "$TOOLS_DATA_DIR" "$AGY_CFG_DIR" "$AGY_STATE_DIR" "$AGY_CLI_DIR" <<'PY'
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
gui_cfg_path.write_text(json.dumps(gui_cfg, indent=2) + "\n")
gui_cfg_path.chmod(0o600)

update_cfg_path = tools_dir / "update_settings.json"
update_cfg_path.write_text(json.dumps({
    "auto_check": False,
    "auto_install": False,
    "last_check_time": 0,
    "check_interval_hours": 87600,
    "skipped_version": "99.99.99"
}, indent=2) + "\n")

accounts_index = tools_dir / "accounts.json"
if not accounts_index.exists():
    accounts_index.write_text(json.dumps({"accounts": [], "current_account_id": None}, indent=2) + "\n")

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
gw_cfg_path.write_text(json.dumps(gw_cfg, indent=2) + "\n")
gw_cfg_path.chmod(0o600)

sel_path = agy_cfg_dir / "selection.json"
sel_path.write_text(json.dumps({"mode": "proxy"}, indent=2) + "\n")
sel_path.chmod(0o600)

route_path = agy_state_dir / "route.json"
route_path.write_text(json.dumps({"mode": "proxy"}, indent=2) + "\n")
route_path.chmod(0o600)

client_path = agy_cfg_dir / "client.json"
client_data = {
    "apiKey": gw_key,
    "endpoint": "http://127.0.0.1:5919",
}
client_path.write_text(json.dumps(client_data, indent=2) + "\n")
client_path.chmod(0o600)

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
settings_path.write_text(json.dumps(settings, indent=2) + "\n")
settings_path.chmod(0o600)
PY

echo "[4/6] Writing hardened systemd user services..."
mkdir -p "$SYSTEMD_DIR"

cat > "$SYSTEMD_DIR/antigravity-tools-headless.service" <<EOF
[Unit]
Description=Antigravity Tools API proxy (headless token-efficient fork)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=$HOME
ExecStart=$HOME/.local/bin/antigravity-tools --headless
Environment=RUST_LOG=info
Environment=ANTIGRAVITY_DISABLE_TRAY=1
Environment=ANTIGRAVITY_HEADER_TIMEOUT_SECS=35
Environment=ANTIGRAVITY_SANDBOX_FIRST_BYTES=0
Environment=ABV_BIND_LOCAL_ONLY=1
Restart=always
RestartSec=2
TimeoutStopSec=10
UMask=0077

[Install]
WantedBy=default.target
EOF

cat > "$SYSTEMD_DIR/agy-backend-gateway.service" <<EOF
[Unit]
Description=Token-efficient Gemini gateway for agy
After=network-online.target antigravity-tools-headless.service
Wants=network-online.target antigravity-tools-headless.service
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=$BACKEND_DIR
ExecStart=$VENV_DIR/bin/python -m uvicorn gateway:app --host 127.0.0.1 --port 5919 --no-access-log --timeout-graceful-shutdown 5
Restart=always
RestartSec=2
TimeoutStopSec=10
UMask=0077
MemoryMax=384M

[Install]
WantedBy=default.target
EOF

echo "[5/6] Enabling linger and starting systemd user services..."
loginctl enable-linger "$USER" 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable antigravity-tools-headless.service agy-backend-gateway.service
systemctl --user restart antigravity-tools-headless.service agy-backend-gateway.service

echo "[6/6] Waiting for services to come online..."
ready=0
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:5919/health >/dev/null 2>&1 && \
     curl -fsS http://127.0.0.1:8045/health >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done
if [ "$ready" -ne 1 ]; then
  echo "Gateway or Tools proxy failed to start; inspect both user services." >&2
  exit 1
fi

echo "Installation complete. Run: $VENV_DIR/bin/python $BACKEND_DIR/login.py --wait"

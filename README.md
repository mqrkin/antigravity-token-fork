# Antigravity Token Fork

An unofficial, headless fork of [Antigravity Tools](https://github.com/lbjlaq/Antigravity-Manager) with a local Gemini-compatible gateway for Antigravity CLI (`agy`). It packages a patched Tools proxy, a gateway, and installers for Windows and Linux. WSL2 requires systemd.

The fork is designed to reduce repeated upstream work and improve reliability for long agent sessions. Savings and latency depend on the model, account, workload, and upstream service; they are not guaranteed.

## What changes

- The gateway sends agent traffic to a local Tools proxy and routes recognized background requests to a smaller model.
- Long-session identifiers remain stable across context summaries. Large requests prefer the Sandbox endpoint, and selected single-account retry and signature-cache paths are adjusted.
- Conversation titles are generated locally. **The CLI safety-rater request is also answered locally with a fixed low-severity result; it is not assessed by an upstream safety model.** Review this behavior before using the fork.
- Automatic updates of the patched Tools binary are disabled. Update deliberately from a trusted release or source build.

This is an independent fork, not an official Google product. Usage is subject to your account, model availability, and the applicable upstream terms.

## Before installing

You need an x86-64 Windows or Linux system, Python 3.10 or later, internet access, a Google account with access to the desired models, and a separate installation of Antigravity CLI. Linux needs `systemd --user`, `curl`, Python's `venv` module, and `zstd` for the release archive; WSL2 must have systemd enabled. The installers bind ports `8045` and `5919` to loopback and install Python packages from PyPI.

The installers update Tools and CLI configuration in your user profile and configure background startup. Back up existing configuration if you already use Antigravity Tools or agy. Windows setup stops existing Tools and gateway processes; Linux setup restarts the two user services and can interrupt in-flight requests. The optional `-ResetAccounts` / `--reset-accounts` flags **delete saved Tools accounts**; omit them to keep existing accounts.

Tools request logging is enabled by the installers. Logs can contain prompts and responses; protect the application's data directory accordingly.

## Install on Windows

1. Download and extract `antigravity-fork-windows.zip` from [Releases](https://github.com/mqrkin/antigravity-token-fork/releases).
2. In PowerShell, change to the extracted folder and run:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
   ```

3. The installer starts the proxy and gateway, prints a Google sign-in URL, and waits for the browser callback. Complete sign-in in your own browser.

The installer creates a hidden startup watchdog and installs files under `%LOCALAPPDATA%\antigravity-fork`. It downloads Python with `winget` if necessary. If the archive lacks the executable, it tries the latest release and then a local Rust build.

## Install on Linux or WSL2

1. Download `antigravity-fork-dist.tar.zst` from [Releases](https://github.com/mqrkin/antigravity-token-fork/releases). The Git repository alone does not contain the packaged Linux runtime.
2. Extract and install:

   ```bash
   tar --zstd -xf antigravity-fork-dist.tar.zst
   cd antigravity-fork-dist
   ./install.sh
   "$HOME/.local/share/agy-backends/.venv/bin/python" \
     "$HOME/.local/share/agy-backends/login.py" --wait
   ```

3. Open the printed Google sign-in URL and complete the browser callback. The installer creates and enables the user services `antigravity-tools-headless.service` and `agy-backend-gateway.service`.

## Run agy through the gateway

The installers configure the custom model, but the gateway address and its local API key must be supplied to each shell that runs the standard CLI. The key stays in your user profile; do not paste it into issues or screenshots.

Windows PowerShell:

```powershell
$env:GEMINI_API_KEY = (Get-Content "$env:USERPROFILE\.config\agy-backends\client.json" -Raw | ConvertFrom-Json).apiKey
$env:GOOGLE_GEMINI_BASE_URL = "http://127.0.0.1:5919"
agy --model "Gemini 4 Argon (Medium)"
```

Linux / WSL2:

```bash
export GEMINI_API_KEY="$("$HOME/.local/share/agy-backends/.venv/bin/python" -c 'import json,pathlib; print(json.loads((pathlib.Path.home()/".config/agy-backends/client.json").read_text())["apiKey"])')"
export GOOGLE_GEMINI_BASE_URL="http://127.0.0.1:5919"
agy --model "Gemini 4 Argon (Medium)"
```

These environment variables affect the current shell and its child processes. The default upstream model is `gemini-4-argon-medium`; account access to that model is required.

## Check the installation

`http://127.0.0.1:5919/health` checks that the gateway process responds. It does not verify Google authentication or model availability. Check the signed-in accounts with `login.py --status`, then send a small request through agy to verify the complete path. Requests consume the account's normal quota.

On Linux, inspect service status and logs with:

```bash
systemctl --user status antigravity-tools-headless.service agy-backend-gateway.service
journalctl --user -u antigravity-tools-headless.service -u agy-backend-gateway.service -n 100
```

If a browser on another machine cannot reach the localhost OAuth callback, start `login.py` without `--wait`, copy the full redirected URL, then pass it to `login.py --submit '<URL>'` on the machine running the proxy. Treat the URL as a credential.

## Source and license

The patched Rust application is under `src-tauri/`, the local gateway is under `gateway/`, and the installation scripts are at the repository root. See [INSTALL_FOR_LLM.md](INSTALL_FOR_LLM.md) for a short agent-oriented installation note. The repository includes the upstream [license](LICENSE); review its noncommercial terms before use.

#!/usr/bin/env python3
import argparse
import json
import pathlib
import subprocess
import sys
import urllib.parse
import urllib.request

def get_api_key() -> str:
    cfg_path = pathlib.Path.home() / ".antigravity_tools" / "gui_config.json"
    data = json.loads(cfg_path.read_text())
    return data["proxy"]["api_key"]

def api_call(method: str, path: str, api_key: str, payload=None, timeout: int = 180):
    url = f"http://127.0.0.1:8045{path}"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    body = json.dumps(payload).encode() if payload is not None else b"{}"
    req = urllib.request.Request(
        url,
        data=body if method == "POST" else None,
        headers=headers,
        method=method,
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode()
        return json.loads(raw) if raw.strip() else {}

def main():
    parser = argparse.ArgumentParser(description="Sign in to Antigravity Tools headless fork with your Google account")
    parser.add_argument("--submit", help="Paste either the full localhost callback URL or the OAuth code if browser ran on another machine")
    parser.add_argument("--status", action="store_true", help="List currently logged-in accounts")
    parser.add_argument("--wait", action="store_true", help="Wait for browser callback on localhost after printing OAuth URL")
    args = parser.parse_args()

    api_key = get_api_key()

    if args.status:
        accounts = api_call("GET", "/api/accounts", api_key, timeout=15)
        print(json.dumps(accounts, indent=2, ensure_ascii=False))
        return

    if args.submit:
        val = args.submit.strip()
        code = val
        state = None
        if "code=" in val:
            parsed = urllib.parse.urlparse(val)
            qs = urllib.parse.parse_qs(parsed.query)
            code = qs.get("code", [val])[0]
            state = qs.get("state", [None])[0]
        api_call("POST", "/api/accounts/oauth/submit-code", api_key, {"code": code, "state": state}, timeout=30)
        done = api_call("POST", "/api/accounts/oauth/complete", api_key, {}, timeout=60)
        print("Logged in successfully:", json.dumps(done, indent=2, ensure_ascii=False))
        return

    res = api_call("POST", "/api/accounts/oauth/prepare", api_key, {}, timeout=15)
    url = res["url"]
    print("\nOpen this Google OAuth URL in your browser to sign into your account:\n")
    print(url)
    print("\nIf you are on a remote server / another machine and the browser redirects to a localhost URL that fails to load,")
    print("copy that full localhost redirect URL from the browser address bar and run:")
    print(f"  python3 {pathlib.Path(__file__).resolve()} --submit '<REDIRECT_URL>'\n")

    try:
        import webbrowser
        webbrowser.open(url)
    except Exception:
        pass

    if args.wait:
        print("Waiting for OAuth callback...")
        done = api_call("POST", "/api/accounts/oauth/complete", api_key, {}, timeout=300)
        print("Logged in successfully:", json.dumps(done, indent=2, ensure_ascii=False))

if __name__ == "__main__":
    main()

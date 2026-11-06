"""Integration checks for the configuration emitted by both installers."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fork_gateway", ROOT / "gateway/gateway.py")
gateway = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gateway)


def installer_config(platform):
    if platform == "linux":
        source = (ROOT / "install.sh").read_text(encoding="utf-8")
        return source.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
    source = (ROOT / "install.ps1").read_text(encoding="utf-8")
    return source.split("$InitScript = @'\n", 1)[1].split("\n'@", 1)[0]


class InstallerGatewayIntegration(unittest.TestCase):
    def test_fresh_and_existing_configurations_reach_gateway(self):
        for platform in ("linux", "windows"):
            for existing in (False, True):
                with self.subTest(platform=platform, existing=existing), tempfile.TemporaryDirectory() as tmp:
                    home = Path(tmp)
                    tools = home / ".antigravity_tools"
                    cfg = home / ".config/agy-backends"
                    state = home / ".local/state/agy-backends"
                    cli = home / ".gemini/antigravity-cli"
                    for directory in (tools, cfg, state, cli):
                        directory.mkdir(parents=True)
                    if existing:
                        (cfg / "gateway.json").write_text(json.dumps({"api_key": "existing-key"}))
                        (cli / "settings.json").write_text('''{
                            // A supported JSONC configuration must retain existing values.
                            "customModelsConfig": {"customModels": {"other": {"label": "Other, }"}}},
                            "notifications": false,
                        }''')
                        (tools / "gui_config.json").write_text(json.dumps({
                            "proxy": {"custom_mapping": {"other": "retained"},
                                      "multimodal": {"strip_remote_urls": True},
                                      "preferred_account_id": "existing-account"},
                        }))
                    subprocess.run([sys.executable, "-c", installer_config(platform),
                                    str(tools), str(cfg), str(state), str(cli)], check=True)
                    installed = json.loads((cfg / "gateway.json").read_text())
                    client = json.loads((cfg / "client.json").read_text())
                    settings = json.loads((cli / "settings.json").read_text())
                    self.assertEqual(installed["apiKey"], client["apiKey"])
                    self.assertEqual(client["endpoint"], "http://127.0.0.1:5919")
                    self.assertEqual(settings["model"], "Gemini 4 Argon (Medium)")
                    self.assertEqual(settings["customModelsConfig"]["customModels"]["agy-current"]
                                     ["modelName"], "gemini-api://agy-current")
                    if existing:
                        self.assertEqual(installed["apiKey"], "existing-key")
                        self.assertFalse(settings["notifications"])
                        self.assertEqual(settings["customModelsConfig"]["customModels"]["other"]["label"], "Other, }")
                        proxy = json.loads((tools / "gui_config.json").read_text())["proxy"]
                        self.assertEqual(proxy["custom_mapping"]["other"], "retained")
                        self.assertTrue(proxy["multimodal"]["strip_remote_urls"])
                        self.assertEqual(proxy["preferred_account_id"], "existing-account")
                    with patch.object(gateway, "HOME", home), patch.object(gateway, "STATE", state):
                        self.assertEqual(gateway.current_mode(), "proxy")
                        self.assertEqual(gateway.route("proxy")["model"], "gemini-4-argon-medium")
                        with TestClient(gateway.app) as http:
                            self.assertEqual(http.get("/health").status_code, 200)
                            self.assertEqual(http.get("/v1beta/models").status_code, 401)
                            response = http.get("/v1beta/models", headers={"x-goog-api-key": client["apiKey"]})
                            self.assertEqual(response.status_code, 200)
                            self.assertEqual(response.json()["models"][0]["name"], "models/agy-current")

    def test_invalid_existing_settings_are_not_replaced(self):
        for platform in ("linux", "windows"):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                paths = [root / name for name in ("tools", "cfg", "state", "cli")]
                for directory in paths:
                    directory.mkdir()
                gui = paths[0] / "gui_config.json"
                gui.write_text('{"language": "ru"}')
                settings = paths[3] / "settings.json"
                settings.write_text('{"broken":')
                result = subprocess.run([sys.executable, "-c", installer_config(platform),
                                         *(str(path) for path in paths)], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(gui.read_text(), '{"language": "ru"}')
                self.assertEqual(settings.read_text(), '{"broken":')

    def test_linux_installer_reports_a_missing_proxy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            home, dist, tools = root / "home", root / "dist", root / "bin"
            for directory in (home, dist / "runtime/usr/bin", dist / "gateway", tools):
                directory.mkdir(parents=True)
            for name in ("install.sh", "login.py"):
                shutil.copy2(ROOT / name, dist / name)
            shutil.copy2(ROOT / "gateway/gateway.py", dist / "gateway/gateway.py")
            for name in ("runtime/AppRun", "runtime/AppRun.wrapped", "runtime/usr/bin/antigravity-tools"):
                path = dist / name
                path.write_text("#!/bin/sh\nexit 0\n")
                path.chmod(0o755)
            pip = home / ".local/share/agy-backends/.venv/bin/pip"
            pip.parent.mkdir(parents=True)
            pip.write_text("#!/bin/sh\nexit 0\n")
            pip.chmod(0o755)
            python = pip.parent / "python"
            python.write_text("#!/bin/sh\nexit 0\n")
            python.chmod(0o755)
            for name in ("systemctl", "loginctl", "sleep"):
                path = tools / name
                path.write_text("#!/bin/sh\nexit 0\n")
                path.chmod(0o755)
            curl = tools / "curl"
            curl.write_text('#!/bin/sh\ncase "$*" in *5919/health*) exit 0;; *) exit 7;; esac\n')
            curl.chmod(0o755)
            env = dict(os.environ, HOME=str(home), USER="testuser", PATH=str(tools) + os.pathsep + os.environ["PATH"])
            result = subprocess.run(["bash", str(dist / "install.sh")], cwd=dist, env=env,
                                    capture_output=True, text=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Gateway or Tools proxy failed to start", result.stderr)


if __name__ == "__main__":
    unittest.main()

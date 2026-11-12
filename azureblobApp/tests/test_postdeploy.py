"""Run with: python3 -m unittest discover -s azureblobApp/tests -v"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


def fake_cli():
    name = Path(sys.argv[0]).name
    args = sys.argv[1:]
    root = Path(os.environ["HOOK_TEST_ROOT"])
    with (root / "calls.jsonl").open("a") as log:
        log.write(json.dumps([name, *args]) + "\n")
    outputs = json.loads(os.environ["HOOK_TEST_OUTPUTS"])
    if name == "azd":
        if args[:2] == ["env", "get-values"]:
            if "--output" in args:
                print(json.dumps(outputs))
            else:
                print("\n".join(f'{key}="{value}"' for key, value in outputs.items()))
            return
        if args[:2] == ["env", "get-value"]:
            print(outputs[args[2]])
            return
    if args[:2] == ["extension", "show"]:
        print("connector-namespace")
        return
    if args[:1] == ["rest"]:
        print("tokenBasedAuth" if os.environ["HOOK_TEST_SCENARIO"] == "oauth" else "managedIdentityAuth")
        return
    if args[:3] == ["connector-namespace", "connection", "show"]:
        scenario = os.environ["HOOK_TEST_SCENARIO"]
        if scenario == "error":
            sys.exit(1)
        count_file = root / "status-count"
        count = int(count_file.read_text()) + 1 if count_file.exists() else 1
        count_file.write_text(str(count))
        pending = scenario == "timeout" or (scenario == "propagation" and count == 1)
        print("Initializing" if pending else ("Connected" if scenario == "connected" else "Ready"))
        return
    if args[:3] == ["connector-namespace", "trigger", "list"]:
        print("[]")
        return
    if args[:3] == ["functionapp", "keys", "list"]:
        print("test-callback-key")
        return
    if args[:3] == ["connector-namespace", "trigger", "create"]:
        details = args[args.index("--notification-details") + 1]
        (root / "callback.json").write_text(Path(details[1:]).read_text())
        return
    sys.exit(f"Unexpected CLI call: {name} {args!r}")


class PostdeployTests(unittest.TestCase):
    variants = [
        (sample, shell)
        for sample in ("polling", "webhook")
        for shell in ("bash", "pwsh")
    ]

    def run_hook(self, sample, shell, scenario, preserve=False):
        source = Path(__file__).resolve().parents[1] / sample / "infra" / "scripts"
        with tempfile.TemporaryDirectory(prefix="blob-mi-hook-") as directory:
            root = Path(directory)
            scripts = root / "app" / "infra" / "scripts"
            scripts.mkdir(parents=True)
            suffix = "sh" if shell == "bash" else "ps1"
            for name in (f"postdeploy.{suffix}", f"local-settings.{suffix}"):
                shutil.copyfile(source / name, scripts / name)
            settings_path = root / "app" / "local.settings.json"
            original = b' { "Values": { "custom": "keep" } }\r\n'
            if preserve:
                settings_path.write_bytes(original)
            binary = root / "bin"
            binary.mkdir()
            for name in ("az", "azd"):
                target = binary / name
                target.write_text(f"#!{sys.executable}\n" + Path(__file__).read_text())
                target.chmod(0o700)
            outputs = {
                "resourceGroupName": "test-rg",
                "connectorNamespaceName": "test-namespace",
                "connectorNamespaceConnectionName": "test-connection",
                "connectorPollingEndpoint": "https://example.invalid/api/connectorGateways/test",
                "onUpdatedFileTriggerConfigName": "azureblob-onupdatedfile",
                "functionAppName": "test-function",
                "functionAppDefaultHostname": "example.invalid",
                "monitoredStorageAccountName": "teststorage",
                "monitoredContainerName": "connector-input",
                "AZURE_SUBSCRIPTION_ID": "test-subscription",
            }
            env = dict(os.environ, PATH=f"{binary}{os.pathsep}{os.environ['PATH']}")
            env.update(
                HOOK_TEST_ROOT=str(root),
                HOOK_TEST_OUTPUTS=json.dumps(outputs),
                HOOK_TEST_SCENARIO=scenario,
            )
            if shell == "bash":
                sleep_body = "SECONDS=$((SECONDS + 301))" if scenario == "timeout" else ":"
                command = [
                    "bash", "-c",
                    f'sleep() {{ {sleep_body}; }}; export -f sleep; bash "$1"',
                    "hook-test", str(scripts / "postdeploy.sh"),
                ]
            else:
                increment = 360 if scenario == "timeout" else 1
                wrapper = (
                    "$global:hookTestNow = [datetime]'2026-01-01'; "
                    "function Get-Date { $global:hookTestNow }; "
                    "function Start-Sleep { param($Seconds) "
                    f"$global:hookTestNow = $global:hookTestNow.AddSeconds({increment}) }}; "
                    "& (Join-Path $env:HOOK_TEST_ROOT 'app/infra/scripts/postdeploy.ps1')"
                )
                command = ["pwsh", "-NoLogo", "-NoProfile", "-Command", wrapper]
            result = subprocess.run(
                command, cwd=root / "app", env=env, text=True,
                capture_output=True, timeout=30,
            )
            log = root / "calls.jsonl"
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertFalse(any("list-consent-links" in call for call in calls))
            self.assertEqual(list(scripts.glob(".notification-details*")), [])
            if preserve:
                self.assertEqual(settings_path.read_bytes(), original)
            settings = json.loads(settings_path.read_text())
            callback_path = root / "callback.json"
            callback = json.loads(callback_path.read_text()) if callback_path.exists() else None
            return result, calls, settings, callback

    def test_connected_without_consent_preserves_delivery_setup(self):
        for sample, shell in self.variants:
            with self.subTest(sample=sample, shell=shell):
                result, _, settings, callback = self.run_hook(sample, shell, "connected")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(settings["Values"]["AzureWebJobsStorage"], "UseDevelopmentStorage=true")
                if sample == "polling":
                    self.assertEqual(
                        settings["Values"]["OnUpdatedFileTriggerConfigName"],
                        "azureblob-onupdatedfile",
                    )
                    self.assertIsNone(callback)
                else:
                    self.assertEqual(
                        callback["callbackUrl"],
                        "https://example.invalid/runtime/webhooks/connector?functionName=OnUpdatedFile",
                    )
                    self.assertEqual(callback["authentication"]["value"], "test-callback-key")

    def test_pending_connection_retries_and_preserves_local_settings(self):
        for sample, shell in self.variants:
            with self.subTest(sample=sample, shell=shell):
                result, calls, _, _ = self.run_hook(sample, shell, "propagation", preserve=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                status_calls = [call for call in calls if call[1:4] == ["connector-namespace", "connection", "show"]]
                self.assertEqual(len(status_calls), 2)

    def test_ready_managed_identity_is_accepted(self):
        for sample, shell in self.variants:
            with self.subTest(sample=sample, shell=shell):
                result, _, _, _ = self.run_hook(sample, shell, "ready")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("is Ready", result.stdout)

    def test_oauth_connection_is_not_mistaken_for_managed_identity(self):
        for sample, shell in self.variants:
            with self.subTest(sample=sample, shell=shell):
                result, _, _, callback = self.run_hook(sample, shell, "oauth")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("not configured for managedIdentityAuth", result.stdout + result.stderr)
                self.assertIsNone(callback)

    def test_status_read_failure_does_not_register_callback(self):
        for sample, shell in self.variants:
            with self.subTest(sample=sample, shell=shell):
                result, _, _, callback = self.run_hook(sample, shell, "error")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Could not read the Azure Blob connection status.", result.stdout + result.stderr)
                self.assertIsNone(callback)

    def test_timeout_reports_identity_permissions_without_consent(self):
        for sample, shell in self.variants:
            with self.subTest(sample=sample, shell=shell):
                result, _, _, callback = self.run_hook(sample, shell, "timeout")
                self.assertNotEqual(result.returncode, 0)
                output = result.stdout + result.stderr
                self.assertIn("Timed out waiting", output)
                self.assertIn("Storage Blob Data Reader", output)
                self.assertIsNone(callback)


if __name__ == "__main__":
    if Path(sys.argv[0]).name in ("az", "azd"):
        fake_cli()
    else:
        unittest.main()

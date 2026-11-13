"""Promote an OutSystems application between environments with the LifeTime
Deployment API v2 (https://<lifetime>/lifetimeapi/rest/v2).

  python scripts/lifetime_deploy.py --source Development --target Test --tag --change-log "..."
  python scripts/lifetime_deploy.py --source Test --target Production --version-key <key>

The application defaults to $APPLICATION_NAME; pass --application to deploy
another one (CI uses it for the separate test application, which goes to Test
only). Auth: a LifeTime service account token in LIFETIME_TOKEN. Prints version_key to
$GITHUB_OUTPUT so later jobs deploy exactly the version that was tested.
"""
import argparse
import os
import sys
import time
from datetime import datetime, timezone

import requests

TERMINAL_OK = {"finished_successful", "finished_with_warnings"}
TERMINAL_FAIL = {"finished_with_errors", "aborted", "needs_user_intervention"}


class LifeTime:
    def __init__(self, base_url: str, token: str):
        self.base = base_url.rstrip("/") + "/lifetimeapi/rest/v2"
        self.s = requests.Session()
        self.s.headers.update({"Authorization": f"Bearer {token}", "Accept": "application/json"})

    def _req(self, method: str, path: str, **kw):
        r = self.s.request(method, self.base + path, timeout=120, **kw)
        if r.status_code >= 400:
            sys.exit(f"LifeTime {method} {path} failed: {r.status_code} {r.text}")
        return r.json() if r.content else None

    def env_key(self, name: str) -> str:
        for e in self._req("GET", "/environments/"):
            if e["Name"].lower() == name.lower():
                return e["Key"]
        sys.exit(f"Environment '{name}' not found")

    def app_key(self, name: str) -> str:
        for a in self._req("GET", "/applications/"):
            if a["Name"].lower() == name.lower():
                return a["Key"]
        sys.exit(f"Application '{name}' not found")

    def tag(self, env: str, app: str, change_log: str) -> str:
        version = datetime.now(timezone.utc).strftime("%Y.%m.%d.%H%M")
        body = {"ChangeLog": change_log, "Version": version}
        return self._req("POST", f"/environments/{env}/applications/{app}/versions/", json=body)["ApplicationVersionKey"]

    def deploy(self, source: str, target: str, app: str, version: str, notes: str) -> str:
        plan = {
            "ApplicationOperations": [{"ApplicationKey": app, "ApplicationVersionKey": version, "DeployOnlyChangedModules": False}],
            "SourceEnvironmentKey": source,
            "TargetEnvironmentKey": target,
            "Notes": notes,
        }
        key = self._req("POST", "/deployments/", json=plan)
        self._req("POST", f"/deployments/{key}/start/")
        return key

    def wait(self, key: str, timeout_s: int = 3600) -> None:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            status = self._req("GET", f"/deployments/{key}/status/")["DeploymentStatus"]
            print(f"deployment {key}: {status}", flush=True)
            if status in TERMINAL_OK:
                return
            if status in TERMINAL_FAIL:
                sys.exit(f"Deployment ended with status {status}")
            time.sleep(20)
        sys.exit("Timed out waiting for the deployment")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--source", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--application", default=os.environ.get("APPLICATION_NAME"))
    p.add_argument("--tag", action="store_true", help="tag a new version in the source environment first")
    p.add_argument("--change-log", default="Automated release")
    p.add_argument("--version-key", help="deploy an already tagged version")
    a = p.parse_args()
    if not a.application:
        sys.exit("--application or APPLICATION_NAME is required")

    lt = LifeTime(os.environ["LIFETIME_URL"], os.environ["LIFETIME_TOKEN"])
    src, tgt, app = lt.env_key(a.source), lt.env_key(a.target), lt.app_key(a.application)
    version = lt.tag(src, app, a.change_log) if a.tag else a.version_key
    if not version:
        sys.exit("Either --tag or --version-key is required")

    key = lt.deploy(src, tgt, app, version, notes=f"CI: {a.change_log}")
    lt.wait(key)

    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as fh:
            fh.write(f"version_key={version}\n")
    print(f"Deployed version {version} from {a.source} to {a.target}")


if __name__ == "__main__":
    main()

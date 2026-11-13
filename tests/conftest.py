"""Shared fixtures.

APP_BASE_URL is the root of the OutSystems environment, e.g.
  https://<env>.outsystemscloud.com
The app is split into modules (see docs/architecture.md, ADR-8), so each suite
derives the module it talks to from that root:
  UI         {APP_BASE_URL}/HDBResale
  ResaleAPI  {APP_BASE_URL}/HDBResale_API/rest/ResaleAPI
  Self-tests {APP_BASE_URL}/HDBResale_Tests/rest/SelfTestAPI/run   (not in Production)
Tests that need the deployed app are skipped when it is not set, so the suite
can run anywhere (CI sets it per environment after deployment).
"""
import os

import pytest
import requests

TIMEOUT = 30
UI_MODULE = "HDBResale"
API_PATH = "HDBResale_API/rest/ResaleAPI"
SELFTEST_PATH = "HDBResale_Tests/rest/SelfTestAPI/run"


@pytest.fixture(scope="session")
def base_url() -> str:
    url = os.environ.get("APP_BASE_URL", "").rstrip("/")
    if not url:
        pytest.skip("APP_BASE_URL not set; skipping tests against the deployed app")
    return url


@pytest.fixture(scope="session")
def ui_url(base_url) -> str:
    return f"{base_url}/{UI_MODULE}"


@pytest.fixture(scope="session")
def http() -> requests.Session:
    s = requests.Session()
    s.headers["Accept"] = "application/json"
    return s


@pytest.fixture(scope="session")
def api(base_url, http):
    """GET helper for ResaleAPI returning (status_code, json_or_None).

    OutSystems omits attributes that hold their default value (0, "", empty
    list) from JSON responses, so callers read optional keys with .get().
    """

    def get(path: str, **params):
        r = http.get(f"{base_url}/{API_PATH}{path}", params=params, timeout=TIMEOUT)
        try:
            body = r.json()
        except ValueError:
            body = None
        return r.status_code, body

    return get

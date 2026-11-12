"""Shared fixtures.

APP_BASE_URL points at the deployed OutSystems module, e.g.
  https://<env>.outsystemscloud.com/Assessment
Tests that need the deployed app are skipped when it is not set, so the suite
can run anywhere (CI sets it per environment after deployment).
"""
import os

import pytest
import requests

TIMEOUT = 30


@pytest.fixture(scope="session")
def base_url() -> str:
    url = os.environ.get("APP_BASE_URL", "").rstrip("/")
    if not url:
        pytest.skip("APP_BASE_URL not set; skipping tests against the deployed app")
    return url


@pytest.fixture(scope="session")
def http() -> requests.Session:
    s = requests.Session()
    s.headers["Accept"] = "application/json"
    return s


@pytest.fixture(scope="session")
def api(base_url, http):
    """GET helper for ResaleAPI returning (status_code, json_or_None)."""

    def get(path: str, **params):
        r = http.get(f"{base_url}/rest/ResaleAPI{path}", params=params, timeout=TIMEOUT)
        try:
            body = r.json()
        except ValueError:
            body = None
        return r.status_code, body

    return get

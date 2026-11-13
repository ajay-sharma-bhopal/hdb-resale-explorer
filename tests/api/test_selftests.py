"""Runs the in-platform unit tests (SelfTest_RunAll) and fails CI on any failure.

The pure logic (month parsing, remaining-lease parsing, record mapping and
validation) lives inside OutSystems, so the tests execute there; this file only
triggers them and reports the results.
The tests live in the separate HDBResale_Tests module (its own application, never
deployed to Production), so a 404 means "not deployed here" and the test is skipped.
"""
import pytest

from conftest import SELFTEST_PATH

TIMEOUT = 60
MIN_EXPECTED_CASES = 20


def test_all_self_tests_pass(base_url, http):
    r = http.get(f"{base_url}/{SELFTEST_PATH}", timeout=TIMEOUT)
    if r.status_code == 404:
        pytest.skip("HDBResale_Tests is not deployed in this environment")
    assert r.status_code == 200, r.text
    report = r.json()

    assert report.get("enabled"), "Self-tests are disabled (Site.SelfTests_Enabled = False) in this environment"
    results = report["results"]
    assert len(results) >= MIN_EXPECTED_CASES, f"expected >= {MIN_EXPECTED_CASES} cases, got {len(results)}"

    failures = [f"{t['Name']}: expected {t['Expected']!r}, got {t['Actual']!r}" for t in results if not t["Passed"]]
    assert not failures, "Failing self-tests:\n  " + "\n  ".join(failures)
    # OutSystems omits default values (0) from JSON, so a missing "failed" means 0.
    assert report.get("passed", 0) == len(results) and report.get("failed", 0) == 0

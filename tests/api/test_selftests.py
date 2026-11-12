"""Runs the in-platform unit tests (SelfTest_RunAll) and fails CI on any failure.

The pure logic (month parsing, remaining-lease parsing, record mapping and
validation) lives inside OutSystems, so the tests execute there; this file only
triggers them and reports the results.
"""

TIMEOUT = 60
MIN_EXPECTED_CASES = 20


def test_all_self_tests_pass(base_url, http):
    r = http.get(f"{base_url}/rest/SelfTestAPI/run", timeout=TIMEOUT)
    assert r.status_code == 200, r.text
    report = r.json()

    assert report["enabled"], "Self-tests are disabled (Site.SelfTests_Enabled = False) in this environment"
    results = report["results"]
    assert len(results) >= MIN_EXPECTED_CASES, f"expected >= {MIN_EXPECTED_CASES} cases, got {len(results)}"

    failures = [f"{t['Name']}: expected {t['Expected']!r}, got {t['Actual']!r}" for t in results if not t["Passed"]]
    assert not failures, "Failing self-tests:\n  " + "\n  ".join(failures)
    assert report["passed"] == len(results) and report["failed"] == 0

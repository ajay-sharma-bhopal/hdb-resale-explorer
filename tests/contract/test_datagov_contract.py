"""Upstream contract tests: detect schema drift in the data.gov.sg dataset before
it silently breaks the sync. They encode every assumption MapResaleRecord and the
parsers make. Run nightly (marker: contract); they need no deployed app."""
import os
import re

import pytest
import requests

pytestmark = pytest.mark.contract

RESOURCE_ID = os.environ.get("DATAGOV_RESOURCE_ID", "d_8b84c4ee58e3cfc0ece0d773c8ca6abc")
URL = "https://data.gov.sg/api/action/datastore_search"
HEADERS = {"x-api-key": os.environ["DATAGOV_API_KEY"]} if os.environ.get("DATAGOV_API_KEY") else {}
EXPECTED_FIELDS = {
    "_id", "month", "town", "flat_type", "block", "street_name", "storey_range",
    "floor_area_sqm", "flat_model", "lease_commence_date", "remaining_lease", "resale_price",
}
MONTH = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")
LEASE = re.compile(r"^\d{1,2} years?( \d{1,2} months?)?$|^\d{1,2}$")
STOREY = re.compile(r"^\d{2} TO \d{2}$")


def fetch(**params):
    r = requests.get(URL, params={"resource_id": RESOURCE_ID, **params}, headers=HEADERS, timeout=60)
    r.raise_for_status()
    body = r.json()
    assert body["success"] is True
    return body["result"]


@pytest.fixture(scope="module")
def sample():
    return fetch(limit=500, sort="_id desc")


def test_fields_unchanged(sample):
    assert EXPECTED_FIELDS <= {f["id"] for f in sample["fields"]}


def test_dataset_size_plausible(sample):
    assert sample["total"] > 200_000


def test_values_match_parser_grammar(sample):
    for rec in sample["records"]:
        assert MONTH.match(rec["month"]), rec
        assert LEASE.match(rec["remaining_lease"]), rec
        assert STOREY.match(rec["storey_range"]), rec
        assert float(rec["resale_price"]) > 0, rec
        assert float(rec["floor_area_sqm"]) > 0, rec
        assert rec["town"].strip() and rec["flat_type"].strip(), rec


def test_paging_by_id_is_deterministic():
    # The resumable load pages with sort=_id asc + offset; repeated reads must agree.
    a = fetch(limit=5, offset=1000, sort="_id asc")["records"]
    b = fetch(limit=5, offset=1000, sort="_id asc")["records"]
    assert [r["_id"] for r in a] == [r["_id"] for r in b]

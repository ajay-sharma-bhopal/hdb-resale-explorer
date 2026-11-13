"""Contract and behaviour tests for the exposed, read-only ResaleAPI."""
import pytest

SORTS = {
    "price_desc": ("ResalePrice", True),
    "price_asc": ("ResalePrice", False),
    "psm_desc": ("PricePerSqm", True),
    "area_desc": ("FloorAreaSqm", True),
}
ITEM_FIELDS = {
    "Id", "TransactionMonth", "Town", "FlatType", "Block", "StreetName", "StoreyRange",
    "FloorAreaSqm", "FlatModel", "LeaseCommenceYear", "RemainingLeaseMonths", "ResalePrice", "PricePerSqm",
}


@pytest.fixture(scope="module")
def health(api):
    status, body = api("/health")
    assert status == 200
    if body.get("status") == "EMPTY":
        pytest.skip("Snapshot not loaded yet (first sync still running)")
    return body


def test_health_reports_fresh_snapshot(health):
    assert health["status"] in {"OK", "STALE"}
    assert health["snapshotRowCount"] > 100_000, "the HDB dataset has >200k rows since 2017"
    assert health["latestMonth"] >= "2024-01-01"


def test_default_page_shape(api, health):
    status, page = api("/transactions")
    assert status == 200
    assert page["totalCount"] == health["snapshotRowCount"]
    assert page.get("startIndex", 0) == 0  # 0 is the default, so OutSystems may omit it
    assert 0 < len(page["items"]) <= 25
    assert ITEM_FIELDS <= set(page["items"][0])
    months = [i["TransactionMonth"] for i in page["items"]]
    assert months == sorted(months, reverse=True), "default sort is most recent first"


def test_town_and_flat_type_filters_are_case_insensitive(api, health):
    status, page = api("/transactions", town="ang mo kio", flatType="4 room", maxRecords=50)
    assert status == 200
    assert 0 < page["totalCount"] < health["snapshotRowCount"]
    assert all(i["Town"] == "ANG MO KIO" and i["FlatType"] == "4 ROOM" for i in page["items"])


@pytest.mark.parametrize("sort_by,expected", SORTS.items())
def test_sorting(api, health, sort_by, expected):
    field, descending = expected
    status, page = api("/transactions", sortBy=sort_by, maxRecords=40)
    assert status == 200
    values = [i[field] for i in page["items"]]
    assert values == sorted(values, reverse=descending)


def test_unknown_sort_falls_back_safely(api, health):
    # SortBy is allow-listed inside the SQL (CASE), so arbitrary input cannot alter the query.
    status, page = api("/transactions", sortBy="1; DROP TABLE x--")
    assert status == 200 and len(page["items"]) > 0


def test_price_and_date_range(api, health):
    status, page = api("/transactions", minPrice=500000, maxPrice=600000,
                       fromMonth="2024-01-01", toMonth="2024-06-01", maxRecords=200)
    assert status == 200 and page["totalCount"] > 0
    for i in page["items"]:
        assert 500000 <= i["ResalePrice"] <= 600000
        assert "2024-01-01" <= i["TransactionMonth"] <= "2024-06-01"


def test_pages_do_not_overlap(api, health):
    _, p1 = api("/transactions", startIndex=0, maxRecords=20)
    _, p2 = api("/transactions", startIndex=20, maxRecords=20)
    assert {i["Id"] for i in p1["items"]}.isdisjoint({i["Id"] for i in p2["items"]})


def test_max_records_is_clamped(api, health):
    _, page = api("/transactions", maxRecords=5000)
    assert len(page["items"]) <= 200


def test_search_by_street(api, health):
    _, page = api("/transactions", search="ang mo kio ave 10", maxRecords=50)
    assert page["totalCount"] > 0
    assert all("ANG MO KIO AVE 10" in i["StreetName"] for i in page["items"])


def test_invalid_date_is_rejected(api, health):
    status, _ = api("/transactions", fromMonth="not-a-date")
    assert status == 400


def test_summary_is_consistent_with_search(api, health):
    filters = {"town": "PUNGGOL", "flatType": "5 ROOM", "fromMonth": "2023-01-01"}
    _, s = api("/summary", **filters)
    _, page = api("/transactions", maxRecords=1, **filters)
    assert s["TransactionCount"] == page["totalCount"] > 0
    assert s["MinPrice"] <= s["MedianPrice"] <= s["MaxPrice"]
    assert s["MinPrice"] <= s["AveragePrice"] <= s["MaxPrice"]
    assert s["LatestMonth"] >= "2023-01-01"

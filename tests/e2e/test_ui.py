"""End-to-end UI tests (Playwright).
Run with: pytest tests/e2e -m e2e --browser chromium   (APP_BASE_URL required)"""
import re

import pytest
from playwright.sync_api import Page, expect

pytestmark = pytest.mark.e2e
NUMBER = re.compile(r"^[\d,]+$")
MONEY = re.compile(r"^S\$[\d,]+$")


def test_dashboard_shows_kpis_and_charts(page: Page, ui_url):
    page.goto(f"{ui_url}/Dashboard")
    expect(page.get_by_text("HDB Resale Market Overview").first).to_be_visible(timeout=30_000)
    expect(page.locator(".kpi-value").first).to_have_text(NUMBER, timeout=30_000)
    expect(page.locator(".kpi-value").nth(1)).to_have_text(MONEY)
    expect(page.get_by_text("Average resale price by month")).to_be_visible()


def test_town_filter_updates_kpis(page: Page, ui_url):
    page.goto(f"{ui_url}/Dashboard")
    total = page.locator(".kpi-value").first
    expect(total).to_have_text(NUMBER, timeout=30_000)
    before = total.inner_text()
    page.get_by_label("Town", exact=True).select_option(label="BISHAN")
    expect(total).not_to_have_text(before, timeout=30_000)


def test_explore_filter_sort_and_open_detail(page: Page, ui_url):
    page.goto(f"{ui_url}/Transactions")
    rows = page.locator("table tbody tr")
    expect(rows.first).to_be_visible(timeout=30_000)
    page.get_by_label("Town", exact=True).select_option(label="QUEENSTOWN")
    expect(page.locator(".result-summary")).to_contain_text("transactions match", timeout=30_000)
    expect(rows.first).to_contain_text("QUEENSTOWN")
    page.get_by_role("columnheader", name="Price").click()
    rows.first.get_by_role("link").click()
    expect(page.locator(".detail-price")).to_have_text(MONEY, timeout=30_000)
    expect(page.get_by_text("How this sale compares")).to_be_visible()


def test_pagination_moves_to_next_page(page: Page, ui_url):
    page.goto(f"{ui_url}/Transactions")
    summary = page.locator(".result-summary")
    expect(summary).to_contain_text("showing 1", timeout=30_000)
    page.get_by_role("button", name=re.compile("next", re.I)).click()
    expect(summary).to_contain_text("showing 26", timeout=30_000)


def test_data_sync_requires_login(page: Page, ui_url):
    page.goto(f"{ui_url}/DataSync")
    expect(page).to_have_url(re.compile(r"Login|InvalidPermissions"), timeout=30_000)


@pytest.mark.parametrize("name,is_admin", [("Demo Admin", True), ("Demo Viewer", False)])
def test_demo_sign_in_by_name(page: Page, ui_url, name, is_admin):
    """Dev/Test only: the login screen lists demo accounts by name; one click signs in.
    Skipped where the panel is absent (the Tests app, which creates them, is not deployed)."""
    page.goto(f"{ui_url}/Login")
    panel = page.locator(".demo-accounts")
    try:
        expect(panel).to_be_visible(timeout=20_000)
    except AssertionError:
        pytest.skip("No demo accounts in this environment")
    expect(panel).not_to_contain_text("HdbDemo")  # no credentials on the page
    page.get_by_role("link", name=re.compile(name)).click()
    expect(page).to_have_url(re.compile(r"/Dashboard"), timeout=30_000)
    expect(page.get_by_text(name).first).to_be_visible(timeout=30_000)
    data_sync = page.get_by_role("link", name="Data Sync")
    if is_admin:
        expect(data_sync).to_be_visible(timeout=30_000)
        data_sync.click()
        expect(page.get_by_text("Recent loads")).to_be_visible(timeout=30_000)
    else:
        expect(page.locator(".kpi-value").first).to_have_text(NUMBER, timeout=30_000)  # page fully loaded
        expect(data_sync).to_have_count(0)

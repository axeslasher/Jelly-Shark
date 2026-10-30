"""Screenshot a page of a server.sh Jellyfin's web dashboard, headless.

usage: dashboard.py <base-url> <out.png> [page]
  page defaults to dashboard/devices; also dashboard/activity, dashboard/users

Signs in as test/test through the API and seeds the web client's stored
credentials, so no login form is driven. Its own session shows up in the
device list as "Chrome · Jellyfin Web". Setup and usage: SKILL.md
§ Checking the server side.
"""

import json
import sys
import time
import urllib.request

from playwright.sync_api import sync_playwright

base, out = sys.argv[1], sys.argv[2]
page_path = sys.argv[3] if len(sys.argv) > 3 else "dashboard/devices"
header = 'MediaBrowser Client="Jellyfin Web", Device="Dashboard check", DeviceId="dashboard-check", Version="1"'

request = urllib.request.Request(
    base + "/Users/AuthenticateByName",
    data=json.dumps({"Username": "test", "Pw": "test"}).encode(),
    headers={"Content-Type": "application/json", "Authorization": header},
)
auth = json.load(urllib.request.urlopen(request, timeout=10))
info = json.load(urllib.request.urlopen(base + "/System/Info/Public", timeout=10))

credentials = {
    "Servers": [
        {
            "Id": info["Id"],
            "Name": info["ServerName"],
            "ManualAddress": base,
            "LocalAddress": base,
            "LastConnectionMode": 2,
            "UserId": auth["User"]["Id"],
            "AccessToken": auth["AccessToken"],
            "DateLastAccessed": int(time.time() * 1000),
        }
    ]
}

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1600, "height": 900})
    page.add_init_script(
        f"localStorage.setItem('jellyfin_credentials', {json.dumps(json.dumps(credentials))});"
    )
    page.goto(f"{base}/web/#/{page_path}")
    # Dashboard pages render client-side after their API calls settle. The
    # web client's own session always appears, so its name proves the page
    # drew real data rather than a skeleton.
    page.wait_for_load_state("networkidle", timeout=30000)
    if page_path == "dashboard/devices":
        page.get_by_text("Jellyfin Web").first.wait_for(timeout=30000)
    page.wait_for_timeout(1000)
    page.screenshot(path=out)
    print(f"Jellyfin {info['Version']}: {page_path} saved to {out}")
    browser.close()

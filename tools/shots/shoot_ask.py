# /// script
# requires-python = ">=3.12"
# dependencies = ["playwright>=1.49"]
# ///
"""Shoot /ask mid-exchange: a question routed to a live persona, answered."""

from __future__ import annotations

import argparse
import asyncio
from pathlib import Path

from playwright.async_api import async_playwright


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:4056")
    parser.add_argument("--out", default="docs/screenshots")
    args = parser.parse_args()
    out = Path(args.out)

    async with async_playwright() as pw:
        browser = await pw.chromium.launch()
        page = await browser.new_page(viewport={"width": 1600, "height": 1000})
        await page.goto(f"{args.base}/ask")
        await page.wait_for_timeout(800)

        await page.fill('input[name="body"]', "why do cats knead blankets?")
        await page.click('button:has-text("ask")')
        # wait for a routed answer to land (fake engine ~1.5s), then settle
        try:
            await page.wait_for_selector(".retro-askturn", timeout=8000)
        except Exception:
            pass
        await page.wait_for_timeout(2500)

        await page.screenshot(path=str(out / "ask.png"))
        print(f"  📸 {out / 'ask.png'}")
        await browser.close()


if __name__ == "__main__":
    asyncio.run(main())

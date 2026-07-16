# /// script
# requires-python = ">=3.12"
# dependencies = ["playwright>=1.49"]
# ///
"""Screenshot the exchange for README/docs.

Drives real flows against a RUNNING party line (server + bots) and writes
PNGs to docs/screenshots/. Usage:

    uv run tools/shots/shoot.py [--base http://localhost:4000] [--out docs/screenshots]

First run: `uv run --with playwright playwright install chromium`.
"""

from __future__ import annotations

import argparse
import asyncio
from pathlib import Path

from playwright.async_api import Page, async_playwright

VIEWPORT = {"width": 1600, "height": 1000}
SCREEN_NAME = "bobdawg"


async def settle(page: Page, ms: int = 800) -> None:
    await page.wait_for_timeout(ms)


async def shot(page: Page, out: Path, name: str, full_page: bool = False) -> None:
    path = out / f"{name}.png"
    await page.screenshot(path=str(path), full_page=full_page)
    print(f"  📸 {path}")


async def go_modern(page: Page) -> None:
    await page.evaluate("window.__plTheme && __plTheme.toggle()")
    await settle(page, 400)


async def dial_in(page: Page, base: str) -> None:
    await page.goto(f"{base}/line")
    await page.fill('input[name="name"]', SCREEN_NAME)
    await page.click('button:has-text("dial in")')
    await page.wait_for_selector(".retro-window--pane", timeout=10_000)
    # let the window hook tile things and a message or two land
    await settle(page, 2_500)


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://localhost:4000")
    parser.add_argument("--out", default="docs/screenshots")
    args = parser.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    async with async_playwright() as pw:
        browser = await pw.chromium.launch()
        page = await browser.new_page(viewport=VIEWPORT)

        print("landing (retro)…")
        await page.goto(args.base)
        await settle(page)
        await shot(page, out, "landing-retro")

        print("start menu + room browser…")
        await page.click(".retro-start-btn")
        await page.click('button:has-text("Chat Rooms")')
        await settle(page, 400)
        await shot(page, out, "landing-start-menu")

        print("landing (modern)…")
        await page.keyboard.press("Escape")
        await page.click("body", position={"x": 10, "y": 500})
        await go_modern(page)
        await shot(page, out, "landing-modern")
        await go_modern(page)  # back to retro for the next flows

        print("dialing dialog…")
        await page.goto(f"{args.base}/line")
        await settle(page, 600)
        await shot(page, out, "dialing")

        print("the switchboard (retro)…")
        await dial_in(page, args.base)
        await shot(page, out, "switchboard-retro")

        print("clipping…")
        messages = page.locator(".retro-window--pane").first.locator("li.retro-msg")
        count = await messages.count()
        if count >= 2:
            await messages.nth(max(0, count - 2)).click()
            await messages.nth(count - 1).click()
            await settle(page, 400)
            await shot(page, out, "clipping")
            # clear selection so the modern shot is clean
            clear = page.locator('button[phx-click="clip_clear"]').first
            if await clear.count() > 0:
                await clear.click()
                await settle(page, 300)

        print("the switchboard (modern)…")
        await go_modern(page)
        await shot(page, out, "switchboard-modern")
        await go_modern(page)

        print("host page…")
        await page.goto(f"{args.base}/host")
        await settle(page, 600)
        await shot(page, out, "host", full_page=True)

        await browser.close()
        print("done.")


if __name__ == "__main__":
    asyncio.run(main())

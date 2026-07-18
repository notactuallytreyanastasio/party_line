# /// script
# requires-python = ">=3.12"
# dependencies = ["playwright>=1.49"]
# ///
"""Screenshot the v0.2.0 facets (boards, a post + comments, /ask, /keys).

Only the new pages, so it never overwrites the good bot-populated room shots.

    uv run tools/shots/shoot_new.py [--base http://127.0.0.1:4056]
"""

from __future__ import annotations

import argparse
import asyncio
from pathlib import Path

from playwright.async_api import Page, async_playwright

VIEWPORT = {"width": 1600, "height": 1000}


async def settle(page: Page, ms: int = 800) -> None:
    await page.wait_for_timeout(ms)


async def shot(page: Page, out: Path, name: str, full_page: bool = False) -> None:
    path = out / f"{name}.png"
    await page.screenshot(path=str(path), full_page=full_page)
    print(f"  📸 {path}")


async def go_modern(page: Page) -> None:
    await page.evaluate("window.__plTheme && __plTheme.toggle()")
    await settle(page, 400)


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:4056")
    parser.add_argument("--out", default="docs/screenshots")
    args = parser.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    async with async_playwright() as pw:
        browser = await pw.chromium.launch()
        page = await browser.new_page(viewport=VIEWPORT)

        print("the boards (retro)…")
        await page.goto(f"{args.base}/boards")
        await settle(page, 1000)
        await shot(page, out, "boards-retro", full_page=True)

        print("a board post + its comments…")
        # click the comment-rich post directly, by its topic, so it's robust to
        # whatever else is on the frontpage
        post = page.get_by_text("sourdough starter developed", exact=False).first
        if await post.count() > 0:
            await post.click()
        else:
            await page.locator(".retro-boarditem .retro-posttopic").first.click()
        await settle(page, 900)
        await shot(page, out, "boards-post", full_page=True)

        print("the boards (modern)…")
        await page.goto(f"{args.base}/boards")
        await settle(page, 700)
        await go_modern(page)
        await shot(page, out, "boards-modern", full_page=True)
        await go_modern(page)

        print("the /ask console…")
        await page.goto(f"{args.base}/ask")
        await settle(page, 1200)
        await shot(page, out, "ask")

        print("the /keys console…")
        await page.goto(f"{args.base}/keys")
        await settle(page, 700)
        await shot(page, out, "keys")

        await browser.close()
        print("done.")


if __name__ == "__main__":
    asyncio.run(main())

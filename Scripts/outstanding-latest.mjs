#!/usr/bin/env node

import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { chromium } from "../.e2e/node_modules/playwright/index.mjs";

const count = Number.parseInt(process.argv[2] || "3", 10);
if (!Number.isInteger(count) || count < 1 || count > 20) {
  throw new Error("가져올 기사 수는 1~20 사이여야 합니다.");
}

const root = path.resolve(import.meta.dirname, "..");
const profileDir = path.join(root, ".outstanding-profile");
const outputDir = path.join(root, ".localdata", "outstanding");
const excluded = new Set([
  "/wrtnseriesc20260828",
  "/newdb20260812",
]);
const nonArticlePrefixes = [
  "/category/", "/tag/", "/author/", "/search/", "/membership", "/login",
  "/info", "/terms", "/privacy", "/youth", "/outmember", "/quotationguide", "/press/",
];

await mkdir(outputDir, { recursive: true });
const context = await chromium.launchPersistentContext(profileDir, {
  channel: "chrome",
  headless: true,
});
const page = context.pages()[0] || (await context.newPage());

await page.goto("https://outstanding.kr/", { waitUntil: "domcontentloaded" });
await page.waitForTimeout(3000);

const candidates = await page.locator("a[href]").evaluateAll((anchors) => {
  const seen = new Set();
  return anchors.flatMap((anchor) => {
    try {
      const url = new URL(anchor.href, location.href);
      if (url.origin !== location.origin || seen.has(url.pathname)) return [];
      seen.add(url.pathname);
      return [{ url: url.href, pathname: url.pathname }];
    } catch {
      return [];
    }
  });
});

const saved = [];
for (const candidate of candidates) {
  if (saved.length >= count) break;
  const { pathname } = candidate;
  if (
    pathname === "/" ||
    excluded.has(pathname) ||
    nonArticlePrefixes.some((prefix) => pathname.startsWith(prefix))
  ) continue;

  await page.goto(candidate.url, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(1800);

  const articleMeta = await page.locator('script[type="application/ld+json"]').allTextContents();
  if (!articleMeta.some((text) => text.includes('"@type":"NewsArticle"'))) continue;

  const title = (await page.title()).trim();
  const mainText = await page.locator("main").innerText().catch(() => "");
  if (mainText.trim().length < 1000) continue;

  const slug = pathname.split("/").filter(Boolean).pop();
  const outputPath = path.join(outputDir, `${slug}.txt`);
  await writeFile(outputPath, `${title}\n${page.url()}\n\n${mainText.trim()}\n`, { mode: 0o600 });
  saved.push({ title, url: page.url(), outputPath, characters: mainText.trim().length });
  console.log(`저장 ${saved.length}/${count}: ${title}`);
}

await context.close();

if (saved.length < count) {
  console.error(`요청한 ${count}개 중 ${saved.length}개만 저장했습니다.`);
  process.exitCode = 1;
} else {
  console.log(JSON.stringify(saved, null, 2));
}

#!/usr/bin/env node

import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { chromium } from "../.e2e/node_modules/playwright/index.mjs";

const defaultUrl = "https://outstanding.kr/wrtnseriesc20260828";
const url = process.argv[2] || defaultUrl;
const root = path.resolve(import.meta.dirname, "..");
const profileDir = path.join(root, ".outstanding-profile");
const outputDir = path.join(root, ".localdata", "outstanding");

await mkdir(outputDir, { recursive: true });

const context = await chromium.launchPersistentContext(profileDir, {
  channel: "chrome",
  headless: false,
  viewport: null,
});

const pages = context.pages();
const page = pages[0] || (await context.newPage());
await page.goto(url, { waitUntil: "domcontentloaded" });

console.log("\n아웃스탠딩 전용 브라우저를 열었습니다.");
console.log("1. 열린 창에서 직접 로그인하세요.");
console.log("2. 읽으려는 기사로 이동해 전체 본문이 보이는지 확인하세요.");
console.log("3. 확인이 끝나면 이 터미널에서 Enter를 누르세요.\n");

process.stdin.setEncoding("utf8");
process.stdin.resume();
await new Promise((resolve) => process.stdin.once("data", resolve));

await page.waitForLoadState("domcontentloaded");
await page.waitForTimeout(1500);

const title = (await page.title()).trim();
const mainText = await page.locator("main").innerText().catch(async () => {
  return await page.locator("body").innerText();
});
const safeName = new URL(page.url()).pathname.split("/").filter(Boolean).pop() || "article";
const outputPath = path.join(outputDir, `${safeName}.txt`);
const output = `${title}\n${page.url()}\n\n${mainText.trim()}\n`;

await writeFile(outputPath, output, { mode: 0o600 });
console.log(`저장 완료: ${outputPath}`);

await Promise.race([
  context.close(),
  new Promise((resolve) => setTimeout(resolve, 3000)),
]);
process.exit(0);

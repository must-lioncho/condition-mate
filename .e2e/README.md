# Dashboard E2E

Headless behaviour checks for the dashboard logic embedded in
`Sources/ConditionManager/Dashboard/DashboardContent.swift`. Each test extracts the
*real* functions from the Swift source (so tests cannot drift from what ships) and
exercises them in Node, with Playwright/Chromium where a DOM is needed.

```sh
npm i            # installs playwright
npx playwright install chromium
npm test         # ime + source + tier + seq + ontrack
```

| File | Covers |
| --- | --- |
| `ime.test.js` / `source.test.js` | Korean IME composition — Enter must not leak the trailing syllable as a duplicate goal |
| `tier.test.js` | Activity-log tier smoothing (10-min carry-forward, neighbor agreement) |
| `seq.test.js` | Stable `goal-NN` numbers — immutable across drag-and-drop reorder |
| `ontrack.test.js` | Derived parent "on track" rollup from child task status |

Backend (real HTTP server, isolated data dir) E2E lives in `../Scripts/e2e-goal-*.sh`.

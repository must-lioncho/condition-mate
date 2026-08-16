#!/usr/bin/env python3
"""UXUI sitemap generator — the app's screen hierarchy, derived from the SOURCE.

Builds a GitBook-style sitemap (big pages -> sub-pages -> UI states) by parsing the
actual code, so the map can never drift silently from what the app really renders:

  - routes      : the `page:` closure in AppDelegate.swift (`path.hasPrefix("/x")`)
  - dashboard   : the VIEW_DEFS tab table in DashboardContent.swift ({k:'input',t:'목록'})
  - 시스템관리   : the `.subtab` buttons in BGMPlayerContent.swift (data-m="map">컨디션맵)
  - UI states   : the flags the screen-catalog probe emits (flags.push('zen') in
                  AppWindow.swift) — zen/counting/run/reward/done/modal/railoff

Each node carries a `match` spec ({mode, path[, view][, flag]}) in the SAME vocabulary
as ScreenCatalog state keys (`mode|path?querykeys|view|flags`), so the 화면 카탈로그 tab
can attach every captured SCR-* screenshot to its sitemap node and show coverage.

Known routes get curated titles/descriptions below; a route that appears in the code
but not in the table still lands in the sitemap (auto entry, flagged "desc":"(신규 라우트
— 설명 미작성)") so new code on main immediately surfaces as an uncovered node.

Output: docs/uxui/sitemap.json (repo). The worker (Scripts/uxui-sitemap.sh) copies it
to <data>/screens/sitemap.json for the app to serve via GET /api/debug/screens/sitemap.

Usage: python3 Scripts/uxui-sitemap.py [--out <path>]
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone, timedelta

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources", "ConditionMate")


def read(rel):
    with open(os.path.join(SRC, rel), encoding="utf-8") as f:
        return f.read()


# ---- curated metadata for known routes (order = display order) -----------------
# mode: which app-window webview renders it (matches ScreenCatalog key's mode field).
# rail: SessionRail present -> the challenge-dial states (zen/run/...) apply here.
KNOWN = [
    ("/",           "대시보드",        "dashboard", True,
     "메인 보드 — 목표/그룹/테이블/토큰/큐/일정/리포트/스프린트/아카이브/히스토리 뷰 탭"),
    ("/goal",       "목표 상세",       "dashboard", True,
     "goal 하나의 페이지 (정의 goal.md + 첨부 + 세션·채팅), ?n=<seq>[&t=task]"),
    ("/goal-add",   "목표 추가",       "dashboard", True,
     "목표 추가/검색 전용 페이지 (컴포저: 작업량·모드·폴더·사진)"),
    ("/bgm-player", "시스템관리 (컨디션 관리)", "bgm", False,
     "컨디션맵·액티비티·액션로그·네트워크 진단·디버그·시스템 로그·화면 카탈로그 탭"),
    ("/equipment",  "장비",           "dashboard", True,
     "장비+숙련도 (포모도로 EXP, 시장 인플레)"),
    ("/cron",       "크론 (워커)",     "dashboard", True,
     "백그라운드 워커 상태 — 주기·최근 실행·오류"),
    ("/worker-log", "워커 로그 (전체)", "dashboard", True,
     "모든 워커의 통합 로그 타임라인"),
    ("/worker",     "워커 로그 (개별)", "dashboard", True,
     "워커 하나의 실행 로그, ?id=<worker>"),
    ("/transcript", "트랜스크립트",     "dashboard", True,
     "Claude 세션 대화 기록 뷰어, ?goal=<id>"),
    ("/breakdown",  "브레이크다운",     "dashboard", True,
     "세션의 분 단위 도구/토큰 분석, ?goal=<id>"),
    ("/bgm-plan",   "BGM 플랜 맵",     "bgm", False,
     "전략3 요일×시간대 선곡 계획 (시스템관리의 모달 iframe으로도 열림)"),
    ("/bgm-timeline-test",      "BGM 타임라인 테스트", "bgm", False, "QA 전용 테스트 페이지"),
    ("/session-continue-test",  "세션 이어가기 테스트", "dashboard", False, "QA 전용 테스트 페이지"),
    ("/lounge-break-test",      "라운지 브레이크 테스트", "bgm", False, "QA 전용 테스트 페이지"),
]

RAIL_STATES = ["zen", "counting", "run", "reward", "done"]   # challenge-dial phases
GLOBAL_STATES = ["modal", "railoff"]                          # any page can show these

FLAG_LABELS = {
    "zen":      "젠 (보드 접힘 · 시작/휴식 화면)",
    "counting": "카운트다운 (자동 시작 5초 리드인)",
    "run":      "세션 중 (다이얼 도킹·보드 표시)",
    "reward":   "수확 대기 (완주 🍅 오브)",
    "done":     "한 판 더? (수확 후 재선택)",
    "modal":    "모달/오버레이 열림",
    "railoff":  "레일 접힘",
}


def parse_routes():
    """Route prefixes from the `page:` closure in AppDelegate.swift, in match order."""
    text = read("AppDelegate.swift")
    m = re.search(r"page:\s*\{\s*\[weak self\] path in(.*?)\n\s*\},", text, re.S)
    if not m:
        sys.exit("uxui-sitemap: cannot find the page: closure in AppDelegate.swift")
    return re.findall(r'path\.hasPrefix\("(/[^"]*)"\)', m.group(1))


def parse_dashboard_views():
    """[(key,title)] from DashboardContent's VIEW_DEFS table."""
    text = read("Dashboard/DashboardContent.swift")
    m = re.search(r"const VIEW_DEFS=\[(.*?)\];", text, re.S)
    if not m:
        sys.exit("uxui-sitemap: cannot find VIEW_DEFS in DashboardContent.swift")
    return re.findall(r"\{k:'([^']+)',t:'([^']+)'\}", m.group(1))


def parse_condition_tabs():
    """[(key,title)] from BGMPlayerContent's .subtab buttons."""
    text = read("Dashboard/BGMPlayerContent.swift")
    tabs = re.findall(r'class="subtab[^"]*"\s+data-m="([^"]+)"[^>]*>([^<]+)</button>', text)
    if not tabs:
        sys.exit("uxui-sitemap: cannot find .subtab buttons in BGMPlayerContent.swift")
    return tabs


def parse_probe_flags():
    """The state-flag vocabulary the screen-catalog probe actually emits."""
    text = read("UI/AppWindow.swift")
    m = re.search(r"screenStateScript = \"\"\"(.*?)\"\"\"", text, re.S)
    if not m:
        sys.exit("uxui-sitemap: cannot find screenStateScript in AppWindow.swift")
    return re.findall(r"flags\.push\('([a-z]+)'\)", m.group(1))


def git_head():
    try:
        return subprocess.check_output(["git", "-C", ROOT, "rev-parse", "HEAD"],
                                       text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""


def main():
    out = os.path.join(ROOT, "docs", "uxui", "sitemap.json")
    if "--out" in sys.argv:
        out = sys.argv[sys.argv.index("--out") + 1]

    routes = parse_routes()
    views = parse_dashboard_views()
    tabs = parse_condition_tabs()
    probe_flags = parse_probe_flags()

    # A flag the probe emits but this generator doesn't label = new state added in
    # code -> surface it (auto label) instead of dropping it.
    flag_labels = dict(FLAG_LABELS)
    for f in probe_flags:
        flag_labels.setdefault(f, f + " (신규 상태 — 라벨 미작성)")

    known = {path: (title, mode, rail, desc) for path, title, mode, rail, desc in KNOWN}
    order = [p for p, *_ in KNOWN]
    # Routes in code but not curated -> append as auto entries (new code surfaces here).
    for r in routes:
        if r not in known:
            known[r] = (r, "dashboard", False, "(신규 라우트 — 설명 미작성)")
            order.append(r)
    # Curated entries whose route vanished from code -> drop (page was removed).
    # "/" (server default) and "/transcript" (page closure's fallback return, no
    # hasPrefix of its own) never appear as hasPrefix routes — always live.
    live = set(routes) | {"/", "/transcript"}
    order = [p for p in order if p in live]

    pages = []
    for path in order:
        title, mode, rail, desc = known[path]
        page = {
            "id": ("dashboard" if path == "/" else path.strip("/").replace("/", "-")),
            "title": title,
            "path": path,
            "mode": mode,
            "desc": desc,
            "states": (RAIL_STATES if rail else []) + GLOBAL_STATES,
            "children": [],
        }
        if path == "/":
            page["src"] = "Sources/ConditionMate/Dashboard/DashboardContent.swift"
            page["children"] = [
                {"id": "dashboard-" + k, "title": t, "view": k} for k, t in views
            ]
        elif path == "/bgm-player":
            page["src"] = "Sources/ConditionMate/Dashboard/BGMPlayerContent.swift"
            page["children"] = [
                {"id": "system-" + k, "title": t, "view": k} for k, t in tabs
            ]
        pages.append(page)

    kst = timezone(timedelta(hours=9))
    doc = {
        "version": 1,
        "generatedAt": datetime.now(kst).isoformat(timespec="seconds"),
        "commit": git_head(),
        "flagLabels": flag_labels,
        "pages": pages,
    }
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
    n_children = sum(len(p["children"]) for p in pages)
    print(f"uxui-sitemap: wrote {out} — pages {len(pages)}, subpages {n_children}, "
          f"flags {len(flag_labels)}, commit {doc['commit'][:8]}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Identify and (optionally) remove app-internal worker sessions that were mirrored
into dashboard goals as noise.

A worker goal is a session-mirrored goal whose transcript's FIRST user prompt begins
with one of the known internal system prompts ("You are a deduplication judge", etc.),
OR whose own title still echoes such a system prompt.

Read-only by default (dry run). Pass --apply to actually remove, via the app's
POST /api/goal/remove (never writes goals.json directly).

Usage:
  python3 cleanup_worker_goals.py                 # dry run
  python3 cleanup_worker_goals.py --apply         # remove via API
"""
import json, os, sys, urllib.request

DATA_DIR = os.environ.get("CM_DATA_DIR", "/Users/lioncho/Work/departtment_service/.condition-manager")
GOALS = os.path.join(DATA_DIR, "review", "goals.json")
PORT = open(os.path.join(DATA_DIR, "dashboard.port")).read().strip()

# First-prompt / title signatures of the app's own claude workers.
SIGNATURES = (
    "You are a deduplication judge",
    "You are a semantic search engine",
    "You are a triage judge",
    "You are an automated UI QA pass",
    "You are an automated bug-hunt agent",
)

def first_user_prompt(tpath):
    """Return the first user-authored text from a Claude transcript .jsonl, or ''."""
    if not tpath or not os.path.isfile(tpath):
        return ""
    try:
        for ln in open(tpath, encoding="utf-8"):
            try:
                o = json.loads(ln)
            except Exception:
                continue
            if o.get("type") != "user":
                continue
            msg = o.get("message") or {}
            c = msg.get("content")
            if isinstance(c, str):
                return c
            if isinstance(c, list):
                for part in c:
                    if isinstance(part, dict) and part.get("type") == "text":
                        return part.get("text", "")
    except Exception:
        pass
    return ""

def looks_like_worker(text):
    t = (text or "").lstrip()
    return any(t.startswith(sig) for sig in SIGNATURES)

def main():
    apply = "--apply" in sys.argv
    data = json.load(open(GOALS, encoding="utf-8"))
    goals = data if isinstance(data, list) else data.get("goals", data)

    hits = []
    for g in goals:
        sid = (g.get("sessionId") or "").strip()
        title = (g.get("text") or "").strip()
        if not sid:
            continue
        # A worker either still echoes the prompt in its title, or its transcript's
        # first prompt does (title-sync may have rewritten the visible title).
        why = None
        if looks_like_worker(title):
            why = "title"
        else:
            fp = first_user_prompt(g.get("transcriptPath", ""))
            if looks_like_worker(fp):
                why = "transcript"
        if why:
            hits.append((g, why))

    print(f"data dir : {DATA_DIR}")
    print(f"port     : {PORT}")
    print(f"scanned  : {len(goals)} goals ({sum(1 for g in goals if (g.get('sessionId') or '').strip())} session-mirrored)")
    print(f"worker noise found: {len(hits)}\n")
    for g, why in hits:
        print(f"  seq {g.get('seq'):>4} [{why:>10}] {g.get('status','?'):>10}  sid {g.get('sessionId','')[:12]}  | {(g.get('text') or '')[:60]}")

    if not hits:
        print("\nNothing to remove.")
        return
    if not apply:
        print(f"\nDRY RUN — re-run with --apply to remove these {len(hits)} goals via POST /api/goal/remove.")
        return

    print(f"\nAPPLYING — removing {len(hits)} goals via API ...")
    ok = 0
    for g, _ in hits:
        body = json.dumps({"id": g["id"]}).encode()
        req = urllib.request.Request(
            f"http://127.0.0.1:{PORT}/api/goal/remove",
            data=body, headers={"Content-Type": "application/json"}, method="POST")
        try:
            urllib.request.urlopen(req, timeout=5).read()
            ok += 1
        except Exception as e:
            print(f"  FAILED seq {g.get('seq')}: {e}")
    print(f"removed {ok}/{len(hits)}")

if __name__ == "__main__":
    main()

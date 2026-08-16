---
name: hero
description: Record and manage team praise (hero) nominations in the team's standard praise format, backed by a local SQLite database, and output a paste-ready message for the Slack #hero channel. Use this whenever the user wants to praise, recognize, or nominate a teammate — trigger on "/hero", "칭찬", "히어로", "노미네이트", "recognition", "praise", "이 사람 잘했어", or when the user describes a teammate's good work and wants it recorded. Also accepts a pasted Slack screenshot: read the teammate's name from the image and use it as the nominee. Also use for looking up past praise entries, listing nominations per person, or exporting the praise log.
---

# Hero — Team Praise Recorder

Record praise nominations for teammates in a fixed format, store every entry in a SQLite database, and output a paste-ready praise message for the Slack `#hero` channel.

## For new teammates (start here)

Install the skill once:

```
cp -R <this folder> ~/.claude/skills/hero
```

Then in any Claude Code session, just describe the praise — "/hero 레보가 새벽 배포 이슈를 잡아줬어" is enough. The skill will ask for whatever detail is missing, save the entry, and hand you a code block to paste into the Slack channel:

https://mustcompany.slack.com/archives/C084315S2F2

This skill never posts to Slack for you. You paste it yourself — that keeps the praise in your own voice and needs no Slack token.

Everything posted in `#hero` is also collected by the Condition Mate app and shown on its Hero tab leaderboard, so posting is what makes the record count.

## Philosophy (read this first — it shapes every entry)

This team treats praise as a growth tool, not a pleasantry. Three rules are non-negotiable:

1. **Detail is respect.** A vague compliment ("he did great") with no specifics is worse than silence — the team considers it mockery. The reason must contain concrete, situational detail: what happened, what the person actually did, and what impact it had (who trusted whom more, what was protected, what was gained). The level of detail also demonstrates the nominator's own professional eye.

2. **Next To Do is mandatory.** Praise without a next step stops growth — the person concludes "I'm good, no more effort needed." Every entry must include a next todo that is the IMMEDIATE next step (one step up, not two). If the user also mentions a longer-term goal (the level after next), record it separately as the next-level goal, not as the next todo.

3. **Skill and level.** Each entry names the skill being praised (e.g., "on-time business") and its level (e.g., lv3), so growth is trackable per skill over time.

## Workflow

Step 0 — Image input (when the user attaches a screenshot):

The user often pastes a Slack screenshot instead of typing a name. Read the image and extract the nominee:
- Take the display name of the message author, or the name in the highlighted mention chip, whichever identifies the person being praised. If the screenshot shows a message written by the user themselves, the nominee is the person mentioned in it, not the author.
- If the name appears with a Korean rendering in parentheses, capture both parts, e.g., "Lebo, Godfrey Emori" and "레보, 갓프리 에모리".
- If the image contains an existing praise entry in the standard format, treat it as a format reference only, not as new content.
- If the image shows more than one candidate name and the intended nominee is unclear, ask the user which person to record before saving.
- The praise content itself always comes from the user's typed text, in Korean or English. The image supplies only the nominee identity.

Step 1 — Gather the required fields from the user's message:
- nominee: the person being praised (name as used in the team, e.g., "Lebo, Godfrey Emori")
- nominee Korean rendering: optional, e.g., "레보, 갓프리 에모리"
- skill and level: e.g., "on-time business" lv3
- reason: the detailed story (see philosophy rule 1)
- next todo: the immediate next step (see philosophy rule 2)
- next level goal: optional, the step after next
- nominator: the person giving the praise. If the user has not stated who they are, ask once — do not assume. (Historically this defaulted to "lion cho"; now that the whole team writes praise, the nominator must be the actual author.)

Step 2 — Quality gate before saving:
- If the reason is vague or lacks concrete detail, do not save yet. Ask the user for the specific situation and impact, explaining that detail-free praise reads as mockery in this culture.
- If the next todo is missing, do not save yet. Ask for it, explaining that praise without a next step stops growth.
- If the next todo the user gives is actually two or more steps ahead, ask which one is the immediate next step and move the rest into the next-level goal.

Step 3 — Compose the praise body in English by default (the team format is English), keeping the Korean name rendering in parentheses. If the user asks for Korean output, write it in Korean instead.

Step 4 — Save to the database using the bundled script:

```
python3 ~/.claude/skills/hero/scripts/hero_db.py add \
  --nominee "NAME" \
  --nominee-korean "한글표기" \
  --nominator "NOMINATOR" \
  --skill "skill name" \
  --level 3 \
  --reason "detailed reason text" \
  --next-todo "immediate next step" \
  --next-level "optional longer-term goal"
```

If the user assigns an explicit entry number (e.g., "이건 [2]번이야"), pass `--id N` to preserve their numbering.

The DB path resolves in this order: `$CM_HERO_DB` if set, otherwise the legacy workspace DB at `agent-mustcompany/storage/hero/heroes.db` when it exists, otherwise `~/.condition-mate/hero/heroes.db`. Run the `where` subcommand to print the resolved path. Never edit the database file by hand — this script is its only writer.

Step 5 — Output the paste-ready message. Print the saved entry inside a fenced code block so the user can copy it in one click, then give the channel link on the following line:

The code block contains only the two-line praise format — no entry number commentary, no surrounding prose, so it pastes into Slack exactly as the team expects.

After the block, tell the user: paste this into #hero (https://mustcompany.slack.com/archives/C084315S2F2). Mention the entry number outside the block, and mention that it will appear on the Condition Mate Hero tab once posted.

Do not attempt to post to Slack directly. This skill has no Slack credentials by design.

## Output format

The standard praise format, exactly:

```
[N] @Nominee Name (한글 표기)
skill-name (lvN) / detailed reason with concrete situation and impact / next todo: the immediate next step (next level: optional longer-term goal)
```

Example:

```
[1] @Someone (아무개)
on-time skill (lv4) / He showed up whenever needed to resolve issues — no matter the time — because he understood Season 2's trust is critical. He woke up for early morning shifts to support us, and because of his commitment, we maintained stakeholder trust. / next todo: this is on us too. We need to prevent these issues at staging with more rigorous testing. Requires stronger QA validation before prod.
```

Keeping this exact shape matters beyond aesthetics: the Condition Mate daemon parses `#hero` messages with a regex built for this format. An off-format message still gets collected, but it falls back to a slower AI parse and may not land on the leaderboard cleanly.

## Other operations

- List all entries: run the script with the `list` command. Filter with `--nominee NAME`.
- Show one entry in praise format: `show <id>`.
- Export the full praise log (all entries, paste-ready): `export`.
- Nomination counts per person: `stats`.
- Print the resolved DB path: `where`.

## Language

Respond to the user in their conversation language (Korean for this team's user), but keep the praise message body in English unless asked otherwise, and keep the database contents exactly as composed.

# Energy & Agent-Value Test Scenarios

Scope: the parent-level AI-work feature. Energy, agent assignment, token, and value
tracking are managed on the PARENT (big-picture goal), not on individual leaf tasks —
per-task entry was too costly and noisy. The unit of concurrency is an ACTIVE PARENT: a
parent whose rollup is on_track because one of its child tasks is in progress. A single
active parent surfaces agent, token, value, and ROI inputs; once two or more parents run
in parallel the dashboard also surfaces energy allocation with a shared 100% cap. The
scenarios below are bound to the real dashboard source (functions are extracted from
DashboardContent.swift and evaluated), so they fail if the production logic drifts.

## Background and fixtures

Fixtures are parent goals and child tasks. A parent is top-level and carries the AI-work
fields: energy percent, an agent list, tokens spent in thousands, and a produced value
score. A child task points to its parent and carries a status (backlog, in_progress, done).
A parent is active when one of its children is in progress. The thresholds under test are
read straight from source so the test tracks any retune: the energy threshold is two active
parents, the agent threshold is one active parent, the high ROI band is one point zero, and
the low ROI band is zero point four. The two blocks gate independently: a single active
parent shows the agent, token, value, and ROI inputs but not energy; energy appears only
once a second parent runs in parallel and the user's finite capacity must be split.

## Scenario 1: Thresholds match the agreed model

Purpose: lock the concurrency model so a silent change is caught.

- Given the dashboard source
- Then the energy threshold equals two
- And the agent threshold equals one
- And the agent threshold is at or below the energy threshold

## Scenario 2: Concurrency counts active parents, not leaf tasks

Purpose: confirm the trigger metric counts parents whose rollup is on_track, and that a
childless top-level goal in progress contributes nothing (management is parent-only).

- Given one parent with an in-progress child alongside another parent with a backlog child
- Then the active-parent count is one
- Given two parents each with an in-progress child
- Then the active-parent count is two
- Given a childless top-level goal set in progress
- Then the active-parent count is zero

## Scenario 3: Energy gauge is hidden for a single active parent

Purpose: one big-picture goal in motion is ordinary work that needs no energy split.

- Given only one active parent
- Then the energy gauge is not rendered

## Scenario 4: Energy gauge appears at two active parents

Purpose: crossing into parallel big-picture work surfaces the energy management banner.

- Given two active parents
- Then the energy gauge is rendered

## Scenario 5: Energy sum counts only active parents' allocations

Purpose: the user's finite capacity is consumed only by parents actually in motion.

- Given two active parents allocated forty and thirty percent
- Then the summed energy is seventy percent
- Given a third parent that is inactive with ninety percent allocated
- Then the summed energy is still seventy percent because inactive energy is excluded

## Scenario 6: Over-capacity warning past the hundred percent cap

Purpose: the whole point of energy management is to flag over-committed parallelism.

- Given two active parents allocated seventy and sixty percent, summing one hundred thirty
- Then the gauge carries the over-capacity state
- And the gauge shows the over-capacity warning text

## Scenario 7: Under-capacity shows remaining energy

Purpose: when within budget the user sees how much capacity is left.

- Given two active parents allocated sixty and thirty percent, summing ninety
- Then the gauge does not carry the over-capacity state
- And the gauge shows ten percent remaining

## Scenario 8: ROI is value divided by tokens, and undefined without tokens

Purpose: ROI is the signal that separates steady output from token burn.

- Given a parent with fifty in value and zero tokens
- Then ROI is undefined
- Given a parent with one hundred in value and fifty thousand tokens
- Then ROI is two point zero

## Scenario 9: ROI bands classify efficiency

Purpose: color banding lets the user tell efficient parallel work from waste at a glance.

- Given a parent whose ROI is two point zero
- Then it falls in the high band
- Given a goal with sixty value over one hundred thousand tokens, ROI zero point six
- Then it falls in the middle band
- Given a goal with fifty value over one million thousand-token units, ROI zero point zero five
- Then it falls in the low band, marking token burn
- Given an undefined ROI
- Then it has no band

## How to run

From the .e2e directory run the energy suite alone with node against energy.test.js, or run
the whole dashboard suite through the package test script. The suite prints one PASS or FAIL
line per assertion and exits non-zero if any assertion fails.

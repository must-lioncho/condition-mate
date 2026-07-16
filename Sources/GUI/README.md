# GUI — reusable AppKit toolkit

App-agnostic AppKit components extracted from Condition Manager (2026-07-13). This target has
**no dependency on ConditionManager types** — everything app-specific is injected — so any other
macOS app (or another package depending on the `GUI` library product) can use it.

## Components

- **AppWindowController** — a native window hosting two persistent WKWebViews served from a
  local HTTP port (`.dashboard` / `.bgm` surfaces), with seamless no-reload mode switching,
  audio-ownership callbacks, zen fold (rail-width start window driven by a JS message channel),
  JS dialog/file-picker/window.open plumbing, frame autosave, and QA snapshot hooks.
  Inject app specifics via `Configuration` (surface paths, titles, zen geometry, documentStart
  scripts, screen-state probe script) and the sinks:
  - `onLog: (String) -> Void` — plain log lines
  - `onTrace: (event, page, detail) -> Void` — lifecycle trace events
  - `screenCatalog: AppWindowScreenCatalogObserver` — screen-state observations + PNG shots
- **MenuController** — status-bar menu built on demand (`NSMenuDelegate`). The host app supplies
  a `() -> MenuState` snapshot closure (everything the menu shows) and conforms to
  `MenuControllerActions` (every click target).
- **LightningGauge** — the menu-bar condition indicator: five pre-rendered animation stages
  driven by a 0…1 `norm` at ~20 Hz. Only needs an `apply: (NSImage) -> Void` installer.
- **Formatting** — game-style progress formatting (hours, milestones, clock, "n분 전").

## Condition Manager wiring

The app-side glue lives in `Sources/ConditionManager/UI/GUIBridge.swift`: the injected JS
payloads (view-trace heartbeat, screen-state probe), the `AppLog`/`ViewTrace`/`ScreenCatalog`
sinks, the `MenuState` builder, and the protocol conformances. When adding app-specific
behavior, put the knowledge there (or pass it through `Configuration`) — never import
ConditionManager types into this target.

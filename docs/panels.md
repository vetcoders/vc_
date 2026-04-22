---
title: Vibecrafted Panels Prototype
phase: T2-P1
status: draft
---

# Panels Backbone

`src/apprt/vibecrafted/panels.zig` is the isolated layout backbone for panel
geometry. `src/apprt/vibecrafted/controller.zig` is the orchestration layer on
top of it. Neither module renders content. Together they own these truths:

1. which panel exists
2. how those panels are arranged in the split tree
3. which panel is focused
4. what kind of surface each panel hosts
5. whether a key is a local board binding or should be forwarded

The backing store is Ghostty's immutable
`src/datastruct/split_tree.zig`. Every layout mutation returns a new tree, then
`Panels` swaps it in and retires the old one.

## Model

- `Panel`
  - stable `id`
- `SplitDirection`
  - `horizontal` means "spawn sibling to the right"
  - `vertical` means "spawn sibling below"
- `FocusDirection`
  - spatial navigation: `left`, `right`, `up`, `down`
  - leaf-order cycling: `previous`, `next`
- `FocusPath`
  - focused `panel_id`
  - current split-tree `handle`
  - `depth` in the tree
- `SurfaceKind`
  - `pty`
  - `custom_tui`
- `InputTarget`
  - `(panel_id, kind)` pair used by runtime glue

## Tree Shape

Starting from one panel:

```text
panel-1
```

After `splitActive(.horizontal)`:

```text
split(horizontal)
├── panel-1
└── panel-2   <- focused
```

After focusing `panel-1` and `splitActive(.vertical)`:

```text
split(horizontal)
├── split(vertical)
│   ├── panel-1
│   └── panel-3   <- focused
└── panel-2
```

## State Transitions

### Create

`empty -> createInitial() -> single panel`

- allocates `panel-<id>`
- initializes a one-leaf `SplitTree`
- focus moves to the created panel

### Split

`focused leaf -> splitActive(direction) -> focused new sibling`

- new panel gets a fresh `PanelId`
- the active leaf is replaced by a split node
- split ratio starts at `0.5`
- zoom is implicitly reset by the underlying split tree

### Focus

`focused panel -> focus(direction) -> focused neighbor`

- spatial navigation delegates to `SplitTree.goto(.spatial = ...)`
- cycling delegates to wrapped `previous` / `next`
- no-op if the resolved target is the current panel

### Close

`focused panel -> closeActive() -> fallback focus`

- if more than one panel exists:
  - resolve fallback focus before removal
  - remove the active leaf from the tree
  - focus moves to the wrapped next panel, or wrapped previous if needed
- if it was the last panel:
  - tree becomes `empty`
  - active focus becomes `null`

## Controller Layer

`Controller` keeps the split tree honest while exposing runtime-friendly
results:

- `createInitial(kind)` returns the first `InputTarget`
- `splitActive(direction, kind)` returns the source panel plus the new target
- `focus(direction)` returns the newly focused target
- `closeActive()` returns either the next focused target or an `emptied` result
- `routeKeyEvent(event)` decides whether the board consumes the key or forwards
  it to the active panel

This keeps T2's policy testable without forcing T1/T3/T4 to share UI code.

## Reserved Keymap

`src/apprt/vibecrafted/keymap.zig` reserves these board-local chords:

- `Ctrl+Shift+H` -> split horizontal
- `Ctrl+Shift+V` -> split vertical
- `Ctrl+Shift+Left/Right/Up/Down` -> move focus
- `Ctrl+Shift+W` -> close active panel

Those bindings are always short-circuited by T2. Everything else is forwarded
to the active panel target so Phase 3 can route PTY and custom TUI input
through different handlers.

## Current Boundary

Phase 1 stops before runtime integration on purpose.

- no GTK wiring
- no `addSurface` / `removeSurface` runtime hook yet
- no real window/widget mounting yet
- no PTY/custom-TUI handler callbacks yet
- no persistence yet

That keeps T2 honest: the orchestration API is testable now, and T1/T3/T4 can
plug into a stable surface later instead of negotiating layout semantics in the
windowing code.

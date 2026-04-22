---
title: Vibecrafted Panels Prototype
phase: T2-P1
status: draft
---

# Panels Backbone

`src/apprt/vibecrafted/panels.zig` is the isolated orchestration layer for
panel layout. It does not render content and it does not know about PTY or
custom TUI surfaces yet. Its only job in Phase 1 is to own three truths:

1. which panel exists
2. how those panels are arranged in the split tree
3. which panel is focused

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

## Current Boundary

Phase 1 stops before runtime integration on purpose.

- no GTK wiring
- no `addSurface` / `removeSurface` callbacks yet
- no PTY/custom-TUI routing yet
- no keymap bindings yet
- no persistence yet

That keeps T2 honest: the orchestration API is testable now, and T1/T3/T4 can
plug into a stable surface later instead of negotiating layout semantics in the
windowing code.

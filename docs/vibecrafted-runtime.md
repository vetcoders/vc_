# Vibecrafted Runtime

The Vibecrafted runtime ships as **vc_** (spoken: "VC Underscore"). Internal
tooling and the build system still refer to the runtime as the
`vibecrafted` apprt and the `vc_board` exe entrypoint — those are stable
Zig identifiers — but every visible surface (binary, app bundle,
desktop entry, install command) carries the `vc_` product mark.

The runtime starts with a minimal `vibecrafted` application runtime so
follow-on tracks can build against a stable apprt surface without dragging
GTK behavior into the new runtime by accident.

## Phase 1 contract

- Toolchain is pinned in `.zig-version` to `0.15.2`.
- `zig build -Druntime=vibecrafted` installs a `vc_` executable.
- `./zig-out/bin/vc_` prints `Vibecrafted runtime v0.0.1` and exits.
- `zig build test` and `zig build test -Druntime=vibecrafted` stay green.
- `zig build test-panels` runs the dedicated Vibecrafted panels contract suite.
- `apprt.vibecrafted` re-exports the panel orchestration API for downstream
  tracks.

## Build

```sh
zig build -Druntime=vibecrafted
```

## Verify

```sh
./zig-out/bin/vc_
zig build test
zig build test-panels
```

## Public orchestration seam

Use `apprt.vibecrafted` as the single import surface for board layout policy:

- `Panels` for split-tree mutations
- `Controller` for surface-kind metadata plus input routing
- `Workspace` for pure named-tab layout bookkeeping
- `WorkspaceController` for named tabs plus kind-aware panel routing
- `SpawnedPanel` for marbles/tab spawns that carry `InputTarget`
- `marblesTabEnvVar` / `marblesTabNameAlloc` / `marblesPaneNameAlloc` for
  marbles orchestration
- `matchBoardKey` / `isReservedBoardKey` for board-local chords

That keeps T2 consumable by T3/T4 without leaking private file layout into
other tracks.

## Current boundary

This runtime is intentionally a scaffold:

- no split tree wiring yet
- no custom UI surface mounting yet
- no workflow execution hooks yet

Those surfaces belong to later phases once the apprt contract is stable.

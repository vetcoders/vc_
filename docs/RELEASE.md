# vc_ Release

This repo ships a dedicated **vc_** (spoken: "VC Underscore") packaging
path on top of the existing Ghostty build surface. The hyphenated
**vc-term** name is provided as a symlink alias inside every bundle so
launchers / shells / package managers that cannot render the trailing
underscore can still reach the runtime.

## Artifacts

The GitHub release tag and artifact basenames stay on the legacy
`vc-board-*` prefix so existing install URLs keep resolving; the
contents are rebranded:

- macOS: `vc-board-macos-arm64.dmg` → contains `vc_.app`
- Linux x86_64: `vc-board-linux-x86_64.tar.gz` → extracts to `vc_/`
- Linux arm64: `vc-board-linux-arm64.tar.gz` → extracts to `vc_/`
- Every artifact emits a sibling `.sha256` file.

Inside each bundle:

- `vc_.app/Contents/MacOS/vc_` (canonical) + `vc-term` symlink
- `vc_/bin/vc_` (canonical) + `vc_/bin/vc-term` symlink

## Local Build

Package macOS:

```bash
./distribution/macos/build-dmg.sh
```

Package Linux:

```bash
./distribution/linux/build-tarball.sh
```

The macOS DMG script builds both missing prerequisites when needed:

- the standalone `vc_` runtime binary (`zig build -Druntime=vibecrafted`)
- the rebranded macOS `.app` shell via `zig build vc-board-app -Druntime=vibecrafted`

The Linux tarball script builds the `vc_` runtime binary when
`zig-out/bin/vc_` is absent (falling back to `zig-out/bin/vc-board` for
checkouts predating the rebrand commit).

The distribution scripts expect the helper binaries to be available through one of these paths:

- `VC_BOARD_AICX_BIN`
- `VC_BOARD_LOCTREE_BIN`
- `VC_BOARD_PRVIEW_BIN`
- `VC_BOARD_RUST_MUX_BIN`
- `VC_BOARD_HELPERS_DIR`
- `PATH`

If `aicx`, `prview`, or `rust-mux` are absent, `distribution/bundle.sh` also tries sibling repos at `../aicx`, `../prview`, and `../rust-mux`.

## CI Release Flow

GitHub Actions workflow: `.github/workflows/vc-board-release.yml`

Trigger modes:

- push tag: `vc-board-v0.1.0`
- manual dispatch with version input such as `0.1.0`

The workflow:

1. Bootstraps Zig `0.15.2`
2. Checks out helper repos
3. Builds helper binaries
4. Builds the `vc_` binary
5. Produces DMG and Linux tarballs
6. Uploads checksums and artifacts
7. Publishes them to the matching GitHub release

## Notarization

`distribution/macos/notarize.sh` staples the DMG with `notarytool`.

Required secrets:

- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

If those secrets are not configured, the workflow skips notarization and still publishes unsigned artifacts.

## Install Bootstrap

`install.sh` is intentionally thin:

- downloads the platform artifact
- downloads the matching `.sha256`
- verifies the checksum
- mounts the DMG on macOS or extracts the tarball on Linux

Override the source mirror with:

```bash
VC_BOARD_RELEASE_BASE_URL=https://example.com/releases ./install.sh
```

## Package-Name Cheat Sheet

| Surface              | Canonical | Fallback     |
| -------------------- | --------- | ------------ |
| Product mark         | `vc_`     | —            |
| Spoken name          | VC Underscore | —        |
| Binary               | `vc_`     | `vc-term`    |
| macOS bundle         | `vc_.app` | —            |
| Installed command    | `vc_`     | `vc-term`    |
| Cargo / npm          | `vc_`     | `vc-term`    |
| PyPI                 | —         | `vc-terminal` / `vc-underscore` |
| Debian / Homebrew    | —         | `vc-terminal` / `vc-underscore` |
| Bundle identifier    | `com.vibecrafted.vc-term` | — |

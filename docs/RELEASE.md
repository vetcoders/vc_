# vc-board Release

This repo now ships a dedicated `vc-board` packaging path on top of the existing Ghostty build surface.

## Artifacts

- macOS: `vc-board-macos-arm64.dmg`
- Linux x86_64: `vc-board-linux-x86_64.tar.gz`
- Linux arm64: `vc-board-linux-arm64.tar.gz`
- Every artifact emits a sibling `.sha256` file.

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

- the standalone `vc-board` runtime binary
- the rebranded macOS `.app` shell via `zig build vc-board-app -Druntime=vibecrafted`

The Linux tarball script builds the `vc-board` runtime binary when `zig-out/bin/vc-board` is absent.

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
4. Builds the `vc-board` binary
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

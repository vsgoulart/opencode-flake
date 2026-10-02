# opencode-flake

A Nix flake that tracks the latest [OpenCode](https://opencode.ai) releases,
both the v1 and v2 lines, for the CLI and the Desktop app. Packages are
repackaged from the official upstream release artifacts (nothing is built from
source), so new releases land here within hours instead of waiting for nixpkgs.

| Package               | Command             | Upstream line                 |
| --------------------- | ------------------- | ----------------------------- |
| `opencode` (default)  | `opencode`          | v1 CLI (GitHub releases)      |
| `opencode-desktop`    | `opencode-desktop`  | v1 Desktop                    |
| `opencode-v2`         | `opencode2`         | v2 CLI (opencode.ai releases) |
| `opencode-desktop-v2` | `opencode2-desktop` | v2 Desktop ("OpenCode 2")     |

`opencode-v1` and `opencode-desktop-v1` are aliases of the v1 packages.
Supported systems: `x86_64-linux` and `aarch64-darwin`.

## Run

```console
nix run github:vsgoulart/opencode-flake
nix run github:vsgoulart/opencode-flake#opencode-v2
nix run github:vsgoulart/opencode-flake#opencode-desktop
nix run github:vsgoulart/opencode-flake#opencode-desktop-v2
```

## Install

```console
nix profile install github:vsgoulart/opencode-flake#opencode
```

### NixOS / home-manager

The overlay replaces nixpkgs' `opencode` and `opencode-desktop` and adds the
v2 packages:

```nix
{
  inputs.opencode.url = "github:vsgoulart/opencode-flake";

  # ...
  nixpkgs.overlays = [ inputs.opencode.overlays.default ];
  environment.systemPackages = with pkgs; [
    opencode
    opencode-desktop
    opencode-v2
    opencode-desktop-v2
  ];
}
```

The overlay also works with home-manager's `programs.opencode` module, which
uses `pkgs.opencode` by default. If you don't use the overlay, reference the
packages directly, e.g. `inputs.opencode.packages.${pkgs.system}.opencode`.

## Living with v1 and v2

All four packages can be installed side by side: the v2 commands are
`opencode2` / `opencode2-desktop`, and the v2 desktop entry is "OpenCode 2"
(`OpenCode 2.app` on macOS). Only v1 Desktop registers the `opencode://` URL
handler.

Upstream ships both Desktop versions with the same application id
(`ai.opencode.desktop`). As a result:

- **They share desktop state** (`~/.config/ai.opencode.desktop` on Linux,
  `~/Library/Application Support/ai.opencode.desktop` on macOS) and a
  single-instance lock. Launching one while the other runs focuses the
  running app.
- On Linux their windows report the same app id/WM class, so a desktop
  environment may group them under the same launcher icon.

## Differences from the nixpkgs packages

- Upstream binaries are used, so they include upstream's own models.dev
  snapshot and build configuration.
- Auto-update is disabled for the CLIs and Desktop (`OPENCODE_DISABLE_AUTOUPDATE=1`).
  On Linux, the Desktop updater feed configuration is removed. On macOS, the
  app bundle is left untouched to keep its notarized signature. An update check
  there can only fail, because the bundle lives in the read-only Nix store.
- On Linux, the Desktop app runs on the Electron build bundled by upstream,
  patched for Nix (not nixpkgs' `electron`), so it always matches what upstream
  tested.
- Wayland: export `NIXOS_OZONE_WL=1` to run the Linux Desktop app natively on
  Wayland.
- nixpkgs' workaround for the legacy `opencode-stable.db` database is not
  included. If you used the nixpkgs package before it switched channels, set
  `OPENCODE_DB=opencode-stable.db` or migrate as described in
  [nixpkgs#558549](https://github.com/NixOS/nixpkgs/pull/558549).

## Updates

`.github/workflows/update.yml` runs twice a day (05:17 and 17:17 UTC) and
whenever it is triggered manually:

1. `scripts/update.sh` finds the newest release of each line and pins it in
   `sources.json`. v1 comes from the newest stable `v1.x.y` GitHub release with
   all needed assets, v2 from the `https://opencode.ai/update/api/latest`
   manifest. Upstream publishes SHA-256 digests for every artifact, so only
   metadata is downloaded. Versions never go backwards.
2. Each changed line is built on Linux and macOS. On macOS the app's code
   signature is also verified.
3. Every line whose builds all passed is committed to `main`. The two lines are
   handled independently, so a broken v2 release doesn't hold back v1 (or vice
   versa). A failed build fails the workflow run, and the line is retried on the
   next run.

To update a local checkout manually (requires `gh`, `jq`, `curl` and `nix`):

```console
bash scripts/update.sh
nix build .#opencode .#opencode-v2 .#opencode-desktop .#opencode-desktop-v2
```

The v2 manifest is an undocumented opencode.ai API. If it changes, the update
workflow will fail loudly rather than pin anything unexpected.

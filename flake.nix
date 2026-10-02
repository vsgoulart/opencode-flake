{
  description = "OpenCode v1 and v2 (CLI and Desktop), repackaged from upstream release artifacts";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      # Pinned upstream artifacts; maintained by scripts/update.sh.
      sources = lib.importJSON ./sources.json;

      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      releaseUrl = version: "https://github.com/anomalyco/opencode/releases/tag/v${version}";
      # v2 is tagged upstream but not published as a GitHub release.
      treeUrl = version: "https://github.com/anomalyco/opencode/tree/v${version}";

      mkPackages = pkgs: {
        opencode = pkgs.callPackage ./nix/cli.nix {
          pname = "opencode";
          source = sources.v1.cli;
          mainProgram = "opencode";
          completionStyle = "yargs";
          description = "AI coding agent built for the terminal";
          changelog = releaseUrl sources.v1.cli.version;
        };

        opencode-desktop = pkgs.callPackage ./nix/desktop.nix {
          pname = "opencode-desktop";
          source = sources.v1.desktop;
          mainProgram = "opencode-desktop";
          desktopId = "ai.opencode.desktop";
          desktopName = "OpenCode";
          urlSchemeHandler = true;
          description = "AI coding agent desktop client";
          changelog = releaseUrl sources.v1.desktop.version;
        };

        opencode-v2 = pkgs.callPackage ./nix/cli.nix {
          pname = "opencode-v2";
          source = sources.v2.cli;
          mainProgram = "opencode2";
          completionStyle = "flag";
          description = "AI coding agent built for the terminal (v2)";
          changelog = treeUrl sources.v2.cli.version;
        };

        opencode-desktop-v2 = pkgs.callPackage ./nix/desktop.nix {
          pname = "opencode-desktop-v2";
          source = sources.v2.desktop;
          mainProgram = "opencode2-desktop";
          desktopId = "ai.opencode.desktop2";
          desktopName = "OpenCode 2";
          urlSchemeHandler = false;
          description = "AI coding agent desktop client (v2)";
          changelog = treeUrl sources.v2.desktop.version;
        };
      };
    in
    {
      overlays.default = final: _prev: mkPackages final;

      packages = forAllSystems (
        pkgs:
        let
          packages = mkPackages pkgs;
        in
        packages
        // {
          default = packages.opencode;
          opencode-v1 = packages.opencode;
          opencode-desktop-v1 = packages.opencode-desktop;
        }
      );

      checks = forAllSystems (pkgs: mkPackages pkgs);

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}

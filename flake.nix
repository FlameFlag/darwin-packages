{
  description = "darwin-packages - overlay of Darwin-specific packages for Nixpkgs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs";

  outputs =
    inputs:
    let
      lib = inputs.nixpkgs.lib;
      # Restrict to systems we actually target. `lib.systems.flakeExposed`
      # includes armv6l-linux, i686-linux, etc
      # `nix flake check --all-systems` evaluates legacyPackages for every one
      # of those and trips on any nixpkgs package marked broken on a fringe
      # arch.
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
    in
    {
      /**
        Overlay that adds every package under `pkgs/by-name` to a consumer's
        nixpkgs. Compose this into your own `nixpkgs` overlays list so the
        resulting package set inherits your `config` (e.g. `allowUnfree`)
        rather than being pinned to the nixpkgs this flake imports.
      */
      overlays.default = import ./pkgs/top-level/by-name-overlay.nix {
        baseDirectory = ./pkgs/by-name;
        inherit lib;
      };

      /**
        A nested structure of [packages](https://nix.dev/manual/nix/latest/glossary#package-attribute-set) and other values.

        The "legacy" in `legacyPackages` doesn't imply that the packages exposed
        through this attribute are "legacy" packages. Instead, `legacyPackages`
        is used here as a substitute attribute name for `packages`. The problem
        with `packages` is that it makes operations like `nix flake show`
        nixpkgs unusably slow due to the sheer number of packages the Nix CLI
        needs to evaluate. But when the Nix CLI sees a `legacyPackages`
        attribute it displays `omitted` instead of evaluating all packages,
        which keeps `nix flake show` on Nixpkgs reasonably fast, though less
        information rich.
      */
      legacyPackages = forAllSystems (
        system:
        import ./default.nix {
          inherit system;
          nixpkgsPath = inputs.nixpkgs;
        }
      );

      /**
        Development shells for all systems.
      */
      devShells = forAllSystems (
        system:
        let
          pkgs = inputs.self.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = builtins.attrValues {
              inherit (pkgs)
                nix-update
                ripgrep
                jq
                sd
                ty
                uv
                ruff
                yamlfmt
                just
                ;
              python3 = pkgs.python3.withPackages (
                ps:
                (builtins.attrValues {
                  inherit (ps)
                    tabulate
                    rich
                    typer
                    cogapp
                    ;
                })
              );
            };

            shellHook = ''
              if [ -f pyproject.toml ] && [ -f uv.lock ]; then
                uv sync --frozen --quiet 2>/dev/null || true
              fi
            '';
          };
        }
      );

      formatter = forAllSystems (system: inputs.self.legacyPackages.${system}.nixfmt);

      apps = forAllSystems (
        system:
        let
          pkgs = inputs.self.legacyPackages.${system};
        in
        {
          update = {
            type = "app";
            meta.description = "Update packages and verify changed builds";
            program = toString (
              pkgs.writeShellScript "update" ''
                exec ${pkgs.uv}/bin/uv run --project ${inputs.self} \
                  ${inputs.self}/scripts/update.py "$@"
              ''
            );
          };
          gen-pkg-table = {
            type = "app";
            meta.description = "Regenerate the README package table";
            program = toString (
              pkgs.writeShellScript "gen-pkg-table" ''
                exec ${pkgs.uv}/bin/uv run --project ${inputs.self} \
                  ${inputs.self}/scripts/gen-pkg-table.py "$@"
              ''
            );
          };
        }
      );
    };
}

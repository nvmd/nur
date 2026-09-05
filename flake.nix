{
  description = "My personal NUR repository";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };
  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
    }:
    let
      lib = nixpkgs.lib;
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;

      # tracked channels to run the `checks` against
      channels = {
        stable = nixpkgs;
        unstable = nixpkgs-unstable;
      };

      pkgss = forAllSystems (
        system: lib.mapAttrs (_: channel: import channel { inherit system; }) channels
      );

      # default channel backs `legacyPackages`, `packages`, `devShells` and the
      # nur entry point (default.nix)
      defaultChannel = "stable";
      defaultPkgs = system: pkgss.${system}.${defaultChannel};

      # the whole check matrix for one channel:
      # * `pkgs`        package set of the channel
      # * `nixpkgsLib`  that channel's flake `lib` (needs `nixosSystem`)
      # Flattened from the nested test registry in ./tests: every check is
      # named by its attribute path joined with `-`, e.g.
      # * mktxp-eval-default-user  (eval tests)
      # * mktxp-basic              (NixOS VM test)
      mkChecks =
        {
          pkgs,
          nixpkgsLib,
        }:
        let
          tests = import ./tests { inherit pkgs nixpkgsLib self; };
        in
        lib.listToAttrs (
          lib.mapAttrsToListRecursiveCond
            # derivations are attrsets too; stop descending at them
            (_: v: !lib.isDerivation v)
            (path: v: lib.nameValuePair (lib.concatStringsSep "-" path) v)
            tests
        );
    in
    {
      legacyPackages = forAllSystems (
        system:
        import ./default.nix {
          pkgs = defaultPkgs system;
        }
      );
      packages = forAllSystems (
        system: nixpkgs.lib.filterAttrs (_: v: nixpkgs.lib.isDerivation v) self.legacyPackages.${system}
      );

      nixosModules = import ./modules/default.nix;

      devShells = forAllSystems (
        system:
        let
          pkgs = defaultPkgs system;
        in
        {
          default = pkgs.mkShell {
            name = "nvmd-nur";
            nativeBuildInputs = with pkgs; [
              nixd
              nixfmt
              nix-output-monitor
            ];
          };
        }
      );

      # Per-system checks, run once per tracked channel.
      # Every attribute is named `<channel>-<check>`, e.g.
      # * nix build .#checks.aarch64-darwin.stable-mktxp-basic
      # * nix build .#checks.aarch64-darwin.unstable-mktxp-basic
      checks = forAllSystems (
        system:
        lib.concatMapAttrs (
          channelName: channel:
          lib.mapAttrs' (n: v: lib.nameValuePair "${channelName}-${n}" v) (mkChecks {
            pkgs = pkgss.${system}.${channelName};
            nixpkgsLib = channel.lib;
          })
        ) channels
      );
    };
}

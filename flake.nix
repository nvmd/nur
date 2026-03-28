{
  description = "My personal NUR repository";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
    in
    {
      legacyPackages = forAllSystems (
        system:
        import ./default.nix {
          pkgs = import nixpkgs { inherit system; };
        }
      );

      packages = forAllSystems (
        system: lib.filterAttrs (_: v: lib.isDerivation v) self.legacyPackages.${system}
      );

      # NixOS module definitions — importable by downstream configurations as
      #   imports = [ nur.nixosModules.mktxp ];
      nixosModules = import ./modules/default.nix;

      # Per-system checks.
      # - Eval tests: pure Nix evaluation + small build-time shell assertions.
      #   No VM needed; run on every platform (including macOS).
      # - VM test: full NixOS integration test, Linux only.
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Eval tests target x86_64-linux NixOS internally but their
          # runCommandLocal derivations build on the local host.
          evalTests = import ./tests/mktxp-eval.nix {
            inherit pkgs;
            nixpkgsLib = nixpkgs.lib;
            mktxpModule = self.nixosModules.mktxp;
          };
        in
        # Prefix every eval-test name for easy identification.
        lib.mapAttrs' (n: v: lib.nameValuePair "mktxp-eval-${n}" v) evalTests
        // lib.optionalAttrs pkgs.stdenv.isLinux {
          # Full NixOS VM integration test — Linux builders only.
          mktxp = import ./tests/mktxp.nix { inherit pkgs self; };
        }
      );
    };
}

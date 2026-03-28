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

      # Per-system checks: module evaluation tests and NixOS VM integration tests.
      # VM tests are only applicable on Linux.
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        lib.optionalAttrs pkgs.stdenv.isLinux {
          # Full NixOS VM integration test.
          mktxp = import ./tests/mktxp.nix { inherit pkgs self; };
        }
      );
    };
}

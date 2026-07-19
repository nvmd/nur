{
  description = "My personal NUR repository";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;

      pkgss = forAllSystems (system: {
        nixpkgs = import nixpkgs { inherit system; };
      });
    in
    {
      legacyPackages = forAllSystems (
        system:
        import ./default.nix {
          pkgs = pkgss.${system}.nixpkgs;
        }
      );
      packages = forAllSystems (
        system: nixpkgs.lib.filterAttrs (_: v: nixpkgs.lib.isDerivation v) self.legacyPackages.${system}
      );

      # NixOS module definitions — importable by downstream configurations as
      #   imports = [ nur.nixosModules.mktxp ];
      nixosModules = import ./modules/default.nix;

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgss.${system}.nixpkgs;
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

      # Per-system checks, flattened from the nested test registry in ./tests.
      # Every check is named by its attribute path joined with `-`, e.g.
      # * mktxp-eval-default-user  (eval tests, every platform)
      # * mktxp-basic              (NixOS VM test, Linux only)
      checks = forAllSystems (
        system:
        let
          tests = import ./tests {
            pkgs = pkgss.${system}.nixpkgs;
            nixpkgsLib = nixpkgs.lib;
            inherit self;
          };
        in
        lib.listToAttrs (
          lib.mapAttrsToListRecursiveCond
            # derivations are attrsets too; stop descending at them
            (_: v: !lib.isDerivation v)
            (path: v: lib.nameValuePair (lib.concatStringsSep "-" path) v)
            tests
        )
      );
    };
}

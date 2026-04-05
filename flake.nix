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

          initrdPkcs11EvalTests = import ./tests/initrd-pkcs11-eval.nix {
            inherit pkgs;
            nixpkgsLib = nixpkgs.lib;
            initrdPkcs11Module = self.nixosModules.initrd-pkcs11;
          };
        in
        # Prefix every eval-test name for easy identification.
        lib.mapAttrs' (n: v: lib.nameValuePair "mktxp-eval-${n}" v) evalTests
        // lib.mapAttrs' (n: v: lib.nameValuePair "initrd-pkcs11-eval-${n}" v) initrdPkcs11EvalTests
        // {
          # Full NixOS VM integration tests — Linux builders only.
          mktxp = import ./tests/mktxp.nix { inherit pkgs self; };
          # Single-boot: enroll + attach (no reboot, no UEFI boot loader).
          initrd-pkcs11 = import ./tests/initrd-pkcs11.nix { inherit pkgs self; };
          # Full boot-cycle: enroll → reboot → initrd unlocks LUKS.
          # Requires KVM; very slow or hangs under pure TCG emulation.
          initrd-pkcs11-boot = import ./tests/initrd-pkcs11-boot.nix { inherit pkgs self; };
        }
      );
    };
}

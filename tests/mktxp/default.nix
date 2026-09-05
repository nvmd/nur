# Tests for the mktxp NixOS module.
{
  pkgs,
  nixpkgsLib,
  self,
}:
{
  # Eval tests: pure Nix evaluation, no VM needed; run on every platform
  # (including macOS). They target x86_64-linux NixOS internally but their
  # runCommandLocal derivations build on the local host.
  eval = import ./eval.nix {
    inherit pkgs nixpkgsLib;
    mktxpModule = self.nixosModules.mktxp;
  };

  # nixos vm integration tests
  basic = import ./basic.nix { inherit pkgs self; };
}

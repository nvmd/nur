# Tests for the oci-registry NixOS module.
{
  pkgs,
  nixpkgsLib,
  self,
}:
{
  # Eval tests only: the module declares data and has no runtime component.
  eval = import ./eval.nix {
    inherit pkgs nixpkgsLib;
    ociRegistryModule = self.nixosModules.oci-registry;
  };
}

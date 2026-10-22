# Registry of all tests, analogous to nixpkgs' nixos/tests/all-tests.nix.
# Returns a nested attrset of derivations; flake.nix flattens it into `checks`.
{
  pkgs,
  nixpkgsLib,
  self,
}:
{
  mktxp = import ./mktxp { inherit pkgs nixpkgsLib self; };
  oci-registry = import ./oci-registry { inherit pkgs nixpkgsLib self; };
}

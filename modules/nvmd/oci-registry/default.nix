# Pinned OCI images read from ./images.toml
#
# Usage example:
# ```nix
# virtualisation.oci-containers.containers.authentik-server.image =
#   config.nvmd.oci-registry.authentik.image;
# ```
{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  entry =
    { name, config, ... }:
    {
      options = {
        repository = mkOption {
          type = types.str;
          example = "ghcr.io/goauthentik/server";
          description = "Host and repository path of the image";
        };
        tag = mkOption {
          type = types.str;
          example = "13.0.2-rootless";
          description = "Image tag";
        };
        digest = mkOption {
          type = types.strMatching "sha256:[0-9a-f]{64}";
          description = "Manifest digest the tag must resolve to";
        };
        image = mkOption {
          type = types.str;
          readOnly = true;
          default = "${config.repository}:${config.tag}@${config.digest}";
          defaultText = lib.literalExpression ''"''${repository}:''${tag}@''${digest}"'';
          description = "Image reference for `${name}`, computed from repository, tag and digest.";
        };
      };
    };
in
{
  options.nvmd.oci-registry = mkOption {
    type = types.attrsOf (types.submodule entry);
    default = { };
    description = "Pinned OCI images keyed by application name.";
  };

  config.nvmd.oci-registry = lib.mapAttrs (_: lib.mapAttrs (_: lib.mkDefault)) (
    lib.importTOML ./images.toml
  );
}

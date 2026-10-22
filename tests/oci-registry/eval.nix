# Non-VM module evaluation tests for the oci-registry NixOS module.
{
  pkgs,
  nixpkgsLib,
  ociRegistryModule,
}:
let
  lib = nixpkgsLib;

  pins = lib.importTOML ../../modules/nvmd/oci-registry/images.toml;

  evalRegistry =
    extraConfig:
    lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ociRegistryModule
        extraConfig
      ];
    };

  assertEval =
    name: checks:
    builtins.seq (builtins.all lib.id checks) (
      pkgs.runCommandLocal "oci-registry-eval-${name}" { } "touch $out"
    );

  # true iff forcing `value` throws (type check, readOnly violation, ...)
  failsToEval = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

  # any pinned entry; the tests do not depend on which one
  someName = builtins.head (builtins.attrNames pins);
  somePin = pins.${someName};

  digestB = "sha256:${lib.strings.replicate 64 "b"}";

  # ---------------------------------------------------------------------------
  # Scenario A: module alone
  # ---------------------------------------------------------------------------
  sA = (evalRegistry { }).config;

  # ---------------------------------------------------------------------------
  # Scenario B: host overrides tag and digest of a pin without mkForce
  # ---------------------------------------------------------------------------
  sB =
    (evalRegistry {
      nvmd.oci-registry.${someName} = {
        tag = "override-tag";
        digest = digestB;
      };
    }).config;

  # ---------------------------------------------------------------------------
  # Scenario C: another module adds an entry of its own
  # ---------------------------------------------------------------------------
  sC =
    (evalRegistry {
      nvmd.oci-registry.extra = {
        repository = "example.org/extra";
        tag = "1.0";
        digest = digestB;
      };
    }).config;

  # ---------------------------------------------------------------------------
  # Scenario D: a pin consumed by virtualisation.oci-containers
  # ---------------------------------------------------------------------------
  sD =
    (evalRegistry (
      { config, ... }:
      {
        virtualisation.oci-containers.containers.test.image = config.nvmd.oci-registry.${someName}.image;
      }
    )).config;
in
{
  # --------------------------------------------------------------------------
  # 1. Every images.toml entry is exposed with image = repository:tag@digest
  # --------------------------------------------------------------------------
  toml-entries = assertEval "toml-entries" (
    [
      (lib.assertMsg (
        builtins.attrNames sA.nvmd.oci-registry == builtins.attrNames pins
      ) "registry entries must match the images.toml tables")
    ]
    ++ lib.mapAttrsToList (
      name: pin:
      lib.assertMsg (
        sA.nvmd.oci-registry.${name}.image == "${pin.repository}:${pin.tag}@${pin.digest}"
      ) "${name}: image must be repository:tag@digest from images.toml"
    ) pins
  );

  # --------------------------------------------------------------------------
  # 2. Pins are mkDefault: a plain host definition overrides them
  # --------------------------------------------------------------------------
  override-without-force = assertEval "override-without-force" [
    (lib.assertMsg (
      sB.nvmd.oci-registry.${someName}.image == "${somePin.repository}:override-tag@${digestB}"
    ) "host tag/digest must replace the pin; repository must be kept")
  ];

  # --------------------------------------------------------------------------
  # 3. Other modules can add entries next to the pinned ones
  # --------------------------------------------------------------------------
  extra-entry = assertEval "extra-entry" [
    (lib.assertMsg (
      sC.nvmd.oci-registry.extra.image == "example.org/extra:1.0@${digestB}"
    ) "extra entry must compute its image")
    (lib.assertMsg (sC.nvmd.oci-registry ? ${someName}) "pinned entries must be kept")
  ];

  # --------------------------------------------------------------------------
  # 4. Option constraints: digest format and read-only image
  # --------------------------------------------------------------------------
  constraints = assertEval "constraints" [
    (lib.assertMsg (failsToEval
      (evalRegistry { nvmd.oci-registry.${someName}.digest = "sha256:abc"; })
      .config.nvmd.oci-registry.${someName}.image
    ) "a digest not matching sha256:<64 hex> must be rejected")
    (lib.assertMsg (failsToEval
      (evalRegistry { nvmd.oci-registry.${someName}.image = "example.org/x:1"; })
      .config.nvmd.oci-registry.${someName}.image
    ) "defining the read-only image option must be rejected")
  ];

  # --------------------------------------------------------------------------
  # 5. Usage with virtualisation.oci-containers (default backend: podman)
  # --------------------------------------------------------------------------
  oci-containers-usage = assertEval "oci-containers-usage" [
    (lib.assertMsg (lib.hasInfix sA.nvmd.oci-registry.${someName}.image
      sD.systemd.services.podman-test.script
    ) "the pinned image reference must be passed to podman run")
  ];
}

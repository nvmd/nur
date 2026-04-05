# Non-VM module evaluation tests for the mktxp NixOS module.
#
# All assertions are evaluated at Nix eval time using lib.assertMsg +
# builtins.seq. No string context is discarded, no shell environment variables
# are passed, and no x86_64-linux derivations are built — the runCommandLocal
# stubs are trivially host-native. A failed assertion throws at eval time;
# `nix flake check` reports it as an evaluation error rather than a build
# failure.
{
  pkgs,
  nixpkgsLib,
  mktxpModule,
}:
let
  lib = nixpkgsLib;

  # Evaluate the mktxp NixOS module with an arbitrary extra config attrset.
  # Always targets x86_64-linux so eval tests run on any host (including macOS).
  evalMktxp =
    extraConfig:
    lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        mktxpModule
        extraConfig
      ];
    };

  # Evaluate a list of lib.assertMsg checks at Nix eval time, then return a
  # trivial host-native derivation. Each check must return true; any false
  # condition throws immediately via lib.assertMsg.
  assertEval =
    name: checks:
    builtins.seq
      (builtins.all lib.id checks)
      (pkgs.runCommandLocal "mktxp-eval-${name}" { } "touch $out");

  # ---------------------------------------------------------------------------
  # Scenario A: single router, custom listen address, boolean and null values
  # ---------------------------------------------------------------------------
  scenarioA = evalMktxp {
    services.mktxp = {
      enable = true;
      settings = {
        listen = "127.0.0.1:49090";
        verbose_mode = true;
        fetch_routers_in_parallel = false;
        max_worker_threads = 8;
      };
      routers = {
        default.settings = {
          health = true;
          bgp = false;
          custom_labels = null;
        };
        "home-router".settings = {
          hostname = "192.168.88.1";
          port = 8728;
          bgp = true;
        };
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Scenario B: credentials_file as a plain freeform key
  # ---------------------------------------------------------------------------
  scenarioB = evalMktxp {
    services.mktxp = {
      enable = true;
      routers."secure-router".settings = {
        hostname = "10.0.0.1";
        credentials_file = "/run/secrets/mktxp-router";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Scenario C: custom user / group
  # ---------------------------------------------------------------------------
  scenarioC = evalMktxp {
    services.mktxp = {
      enable = true;
      user = "prometheus";
      group = "prometheus";
      routers."r".settings.hostname = "192.168.1.1";
    };
    users.users.prometheus = {
      isSystemUser = true;
      group = "prometheus";
    };
    users.groups.prometheus = { };
  };

  sA = scenarioA.config;
  sB = scenarioB.config;
  sC = scenarioC.config;
in
{
  # --------------------------------------------------------------------------
  # 1. Service configuration — ExecStart, StateDirectory, wantedBy
  # --------------------------------------------------------------------------
  service-config = assertEval "service-config" [
    (lib.assertMsg
      (lib.hasSuffix "--cfg-dir /var/lib/mktxp export" sA.systemd.services.mktxp.serviceConfig.ExecStart)
      "ExecStart must end with --cfg-dir /var/lib/mktxp export"
    )
    (lib.assertMsg
      (sA.systemd.services.mktxp.serviceConfig.StateDirectory == "mktxp")
      "StateDirectory must be 'mktxp'"
    )
    (lib.assertMsg
      (sA.systemd.services.mktxp.serviceConfig.StateDirectoryMode == "0700")
      "StateDirectoryMode must be 0700"
    )
    (lib.assertMsg
      (builtins.elem "multi-user.target" sA.systemd.services.mktxp.wantedBy)
      "service must be wanted by multi-user.target"
    )
  ];

  # --------------------------------------------------------------------------
  # 2. Default user / group creation
  # --------------------------------------------------------------------------
  default-user = assertEval "default-user" [
    (lib.assertMsg
      sA.users.users.mktxp.isSystemUser
      "mktxp user must be a system user"
    )
    (lib.assertMsg
      (sA.users.users.mktxp.group == "mktxp")
      "mktxp user must belong to the mktxp group"
    )
    (lib.assertMsg
      (sA.users.groups ? mktxp)
      "mktxp group must be defined"
    )
  ];

  # --------------------------------------------------------------------------
  # 3. Custom user: no auto-created user/group when names differ
  # --------------------------------------------------------------------------
  custom-user = assertEval "custom-user" [
    (lib.assertMsg
      (!(sC.users.users ? mktxp))
      "module must not create mktxp user when a custom user is set"
    )
    (lib.assertMsg
      (sC.systemd.services.mktxp.serviceConfig.User == "prometheus")
      "service User must match the configured user"
    )
  ];

  # --------------------------------------------------------------------------
  # 4. BindReadOnlyPaths — immutable config overlay
  # --------------------------------------------------------------------------
  bind-read-only-paths = assertEval "bind-read-only-paths" [
    (lib.assertMsg
      (
        builtins.any
          (p: lib.hasSuffix ":/var/lib/mktxp/_mktxp.conf" p)
          sA.systemd.services.mktxp.serviceConfig.BindReadOnlyPaths
      )
      "BindReadOnlyPaths must include a mapping onto /var/lib/mktxp/_mktxp.conf"
    )
    (lib.assertMsg
      (
        builtins.any
          (p: lib.hasSuffix ":/var/lib/mktxp/mktxp.conf" p)
          sA.systemd.services.mktxp.serviceConfig.BindReadOnlyPaths
      )
      "BindReadOnlyPaths must include a mapping onto /var/lib/mktxp/mktxp.conf"
    )
  ];

  # --------------------------------------------------------------------------
  # 5. Generated _mktxp.conf content
  # --------------------------------------------------------------------------
  global-conf-content = assertEval "global-conf-content" [
    (lib.assertMsg
      (lib.hasInfix "[MKTXP]" sA.services.mktxp._globalConfigText)
      "[MKTXP] section missing"
    )
    (lib.assertMsg
      (lib.hasInfix "listen = 127.0.0.1:49090" sA.services.mktxp._globalConfigText)
      "listen option not serialised correctly"
    )
    (lib.assertMsg
      (lib.hasInfix "verbose_mode = True" sA.services.mktxp._globalConfigText)
      "bool true must serialise as True (Python literal)"
    )
    (lib.assertMsg
      (lib.hasInfix "fetch_routers_in_parallel = False" sA.services.mktxp._globalConfigText)
      "bool false must serialise as False (Python literal)"
    )
    (lib.assertMsg
      (lib.hasInfix "max_worker_threads = 8" sA.services.mktxp._globalConfigText)
      "integer option not serialised correctly"
    )
  ];

  # --------------------------------------------------------------------------
  # 6. Generated mktxp.conf content — sections and value serialisation
  # --------------------------------------------------------------------------
  router-conf-content = assertEval "router-conf-content" [
    (lib.assertMsg
      (lib.hasInfix "[default]" sA.services.mktxp._routerConfigText)
      "[default] section missing"
    )
    (lib.assertMsg
      (lib.hasInfix "[home-router]" sA.services.mktxp._routerConfigText)
      "[home-router] section missing"
    )
    (lib.assertMsg
      (lib.hasInfix "hostname = 192.168.88.1" sA.services.mktxp._routerConfigText)
      "hostname not serialised"
    )
    (lib.assertMsg
      (lib.hasInfix "port = 8728" sA.services.mktxp._routerConfigText)
      "integer port not serialised"
    )
    (lib.assertMsg
      (lib.hasInfix "bgp = True" sA.services.mktxp._routerConfigText)
      "bool bgp=true must appear in per-router section"
    )
    (lib.assertMsg
      (lib.hasInfix "health = True" sA.services.mktxp._routerConfigText)
      "health=true from routers.default missing"
    )
    (lib.assertMsg
      (lib.hasInfix "bgp = False" sA.services.mktxp._routerConfigText)
      "bgp=false from routers.default missing"
    )
    (lib.assertMsg
      (lib.hasInfix "custom_labels = None" sA.services.mktxp._routerConfigText)
      "null must serialise as None (Python literal)"
    )
  ];

  # --------------------------------------------------------------------------
  # 7. credentials_file as a plain freeform key
  # --------------------------------------------------------------------------
  credentials-file-mapping = assertEval "credentials-file-mapping" [
    (lib.assertMsg
      (lib.hasInfix "credentials_file = /run/secrets/mktxp-router" sB.services.mktxp._routerConfigText)
      "credentials_file must appear verbatim in the INI output"
    )
  ];
}

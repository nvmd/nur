# Non-VM module evaluation tests for the mktxp NixOS module.
#
# These verify module correctness entirely at evaluation / build time —
# no virtual machine is required. nixpkgs uses the same pattern for
# lightweight module checks (see e.g. nixos/tests/module-system/).
#
# Each check is a small derivation whose build script asserts a property
# of the evaluated NixOS configuration. A build failure means the test
# failed. `nix flake check` runs them all.
{
  pkgs,
  nixpkgsLib,
  mktxpModule,
}:
let
  # Evaluate the mktxp NixOS module with an arbitrary extra config attrset.
  # Always targets x86_64-linux so eval tests run on any host (including macOS).
  # The shell assertions inside runCommandLocal still execute on the local host.
  evalMktxp =
    extraConfig:
    nixpkgsLib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        mktxpModule
        extraConfig
      ];
    };

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
      defaultRouterSettings = {
        health = true;
        bgp = false;
        custom_labels = null;
      };
      routers."home-router" = {
        hostname = "192.168.88.1";
        port = 8728;
        bgp = true;
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Scenario B: credentialsFile mapping
  # ---------------------------------------------------------------------------
  scenarioB = evalMktxp {
    services.mktxp = {
      enable = true;
      routers."secure-router" = {
        hostname = "10.0.0.1";
        credentialsFile = "/run/secrets/mktxp-router";
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
      routers."r".hostname = "192.168.1.1";
    };
    users.users.prometheus = {
      isSystemUser = true;
      group = "prometheus";
    };
    users.groups.prometheus = { };
  };

  # Write a config text string to a host-system store path for inspection.
  # Using the host pkgs avoids x86_64-linux-only derivations that can't be
  # built on macOS.
  hostConf = name: text: pkgs.writeText name text;

  # Shorthand: run a shell assertion as a local derivation
  assertShell =
    name: env: script:
    pkgs.runCommandLocal "mktxp-eval-${name}" env script;
in
{
  # --------------------------------------------------------------------------
  # 1. Service configuration
  # --------------------------------------------------------------------------
  service-config =
    assertShell "service-config"
      {
        # unsafeDiscardStringContext strips x86_64-linux store deps so the
        # runCommandLocal derivation can build on any host.
        execStart = builtins.unsafeDiscardStringContext scenarioA.config.systemd.services.mktxp.serviceConfig.ExecStart;
        stateDir = scenarioA.config.systemd.services.mktxp.serviceConfig.StateDirectory;
        stateDirMode = scenarioA.config.systemd.services.mktxp.serviceConfig.StateDirectoryMode;
        wantedBy = builtins.toJSON scenarioA.config.systemd.services.mktxp.wantedBy;
      }
      ''
        echo "ExecStart: $execStart"
        [[ "$execStart" == *"--cfg-dir /var/lib/mktxp export" ]] \
          || { echo "FAIL: ExecStart must contain --cfg-dir /var/lib/mktxp export"; exit 1; }

        [[ "$stateDir" == "mktxp" ]] \
          || { echo "FAIL: StateDirectory must be 'mktxp'"; exit 1; }

        [[ "$stateDirMode" == "0700" ]] \
          || { echo "FAIL: StateDirectoryMode must be 0700"; exit 1; }

        echo "$wantedBy" | ${pkgs.jq}/bin/jq -e 'contains(["multi-user.target"])' \
          || { echo "FAIL: service must be wanted by multi-user.target"; exit 1; }

        touch "$out"
      '';

  # --------------------------------------------------------------------------
  # 2. Default user / group creation
  # --------------------------------------------------------------------------
  default-user =
    assertShell "default-user"
      {
        # Access only scalar attrs — toJSON on the whole user record would pull
        # in the shell package (a x86_64-linux derivation).
        userIsSystem = builtins.toJSON scenarioA.config.users.users.mktxp.isSystemUser;
        userGroup = scenarioA.config.users.users.mktxp.group;
        groupDefined = builtins.toJSON (scenarioA.config.users.groups ? mktxp);
      }
      ''
        [[ "$userIsSystem" == "true" ]] \
          || { echo "FAIL: mktxp user must be a system user"; exit 1; }

        [[ "$userGroup" == "mktxp" ]] \
          || { echo "FAIL: mktxp user must belong to the mktxp group"; exit 1; }

        [[ "$groupDefined" == "true" ]] \
          || { echo "FAIL: mktxp group must be defined"; exit 1; }

        touch "$out"
      '';

  # --------------------------------------------------------------------------
  # 3. Custom user: no auto-created user/group when names differ
  # --------------------------------------------------------------------------
  custom-user =
    assertShell "custom-user"
      {
        hasMktxpUser = builtins.toJSON (scenarioC.config.users.users ? mktxp);
        serviceUser = builtins.unsafeDiscardStringContext scenarioC.config.systemd.services.mktxp.serviceConfig.User;
      }
      ''
        # When user = "prometheus", the module must NOT create a "mktxp" user
        [[ "$hasMktxpUser" == "false" ]] \
          || { echo "FAIL: module must not create mktxp user when a custom user is set"; exit 1; }

        [[ "$serviceUser" == "prometheus" ]] \
          || { echo "FAIL: service User must match the configured user"; exit 1; }

        touch "$out"
      '';

  # --------------------------------------------------------------------------
  # 4. Generated _mktxp.conf content
  # --------------------------------------------------------------------------
  global-conf-content =
    assertShell "global-conf-content"
      {
        globalConf = hostConf "_mktxp.conf" scenarioA.config.services.mktxp._globalConfigText;
      }
      ''
        echo "=== _mktxp.conf ==="
        cat "$globalConf"

        grep -q '^\[MKTXP\]' "$globalConf" \
          || { echo "FAIL: [MKTXP] section missing"; exit 1; }

        grep -q 'listen = 127.0.0.1:49090' "$globalConf" \
          || { echo "FAIL: listen option not serialised correctly"; exit 1; }

        grep -q 'verbose_mode = True' "$globalConf" \
          || { echo "FAIL: bool true must serialise as True (Python literal)"; exit 1; }

        grep -q 'fetch_routers_in_parallel = False' "$globalConf" \
          || { echo "FAIL: bool false must serialise as False"; exit 1; }

        grep -q 'max_worker_threads = 8' "$globalConf" \
          || { echo "FAIL: integer option not serialised correctly"; exit 1; }

        touch "$out"
      '';

  # --------------------------------------------------------------------------
  # 5. Generated mktxp.conf content — sections and value serialisation
  # --------------------------------------------------------------------------
  router-conf-content =
    assertShell "router-conf-content"
      {
        routerConf = hostConf "mktxp.conf" scenarioA.config.services.mktxp._routerConfigText;
      }
      ''
        echo "=== mktxp.conf ==="
        cat "$routerConf"

        grep -q '^\[default\]' "$routerConf" \
          || { echo "FAIL: [default] section missing"; exit 1; }

        grep -q '^\[home-router\]' "$routerConf" \
          || { echo "FAIL: [home-router] section missing"; exit 1; }

        # Verify per-router settings
        grep -q 'hostname = 192.168.88.1' "$routerConf" \
          || { echo "FAIL: hostname not serialised"; exit 1; }

        grep -q 'port = 8728' "$routerConf" \
          || { echo "FAIL: integer port not serialised"; exit 1; }

        grep -q 'bgp = True' "$routerConf" \
          || { echo "FAIL: bool bgp=true must appear in per-router section"; exit 1; }

        # Verify default section values
        grep -q 'health = True' "$routerConf" \
          || { echo "FAIL: health=true from defaultRouterSettings missing"; exit 1; }

        grep -q 'bgp = False' "$routerConf" \
          || { echo "FAIL: bgp=false from defaultRouterSettings missing"; exit 1; }

        grep -q 'custom_labels = None' "$routerConf" \
          || { echo "FAIL: null must serialise as None (Python literal)"; exit 1; }

        touch "$out"
      '';

  # --------------------------------------------------------------------------
  # 6. credentialsFile → credentials_file mapping
  # --------------------------------------------------------------------------
  credentials-file-mapping =
    assertShell "credentials-file-mapping"
      {
        routerConf = hostConf "mktxp.conf" scenarioB.config.services.mktxp._routerConfigText;
      }
      ''
        echo "=== mktxp.conf (scenarioB) ==="
        cat "$routerConf"

        grep -q 'credentials_file = /run/secrets/mktxp-router' "$routerConf" \
          || { echo "FAIL: credentialsFile must map to credentials_file key in INI"; exit 1; }

        # The Nix option name must NOT leak into the INI
        grep -q 'credentialsFile' "$routerConf" \
          && { echo "FAIL: Nix-level credentialsFile key must not appear in INI"; exit 1; } || true

        touch "$out"
      '';

  # --------------------------------------------------------------------------
  # 7. ExecStartPre script uses symlinks (not copies)
  # --------------------------------------------------------------------------
  symlink-setup =
    assertShell "symlink-setup"
      {
        # _setupScriptText has store paths stripped (unsafeDiscardStringContext
        # in the module) so it is a pure string — no x86_64-linux deps here.
        setupText = scenarioA.config.services.mktxp._setupScriptText;
      }
      ''
        echo "Setup script body:"
        echo "$setupText"

        echo "$setupText" | grep -q 'ln -sf' \
          || { echo "FAIL: setup script must use ln -sf (symlinks, not copies)"; exit 1; }

        echo "$setupText" | grep -qv '^cp ' \
          || { echo "FAIL: setup script must not use cp"; exit 1; }

        echo "$setupText" | grep -q '/var/lib/mktxp/_mktxp.conf' \
          || { echo "FAIL: setup script must symlink _mktxp.conf"; exit 1; }

        echo "$setupText" | grep -q '/var/lib/mktxp/mktxp.conf' \
          || { echo "FAIL: setup script must symlink mktxp.conf"; exit 1; }

        touch "$out"
      '';
}

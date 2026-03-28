# NixOS module for mktxp — Prometheus Exporter for MikroTik RouterOS devices
# https://github.com/akpw/mktxp
#
# RFC-42 is followed: the INI-mapped settings use freeformType so users can
# pass any upstream option through without this module redeclaring every known
# key. Nix-specific options live at the outer routers.<name> level, while
# routers.<name>.settings holds the freeform INI config.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.mktxp;

  inherit (lib)
    literalExpression
    mapAttrs
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    optionalAttrs
    types
    ;

  # ---------------------------------------------------------------------------
  # INI generation — Python-style literals required by configobj
  # ---------------------------------------------------------------------------

  # emits Python literals so that mktxp's `configobj` can parse the config
  toINI = lib.generators.toINI (
    let
      toConfValue =
        v:
        if v == null then
          "None"
        else if v == true then
          "True"
        else if v == false then
          "False"
        else if builtins.isString v && v == "" then
          "\"\""
        else
          toString v;
    in
    {
      mkKeyValue = k: v: "${k} = ${toConfValue v}";
    }
  );

  # Plain Nix strings — host-portable, no store path context.
  # Exposed via _globalConfigText / _routerConfigText for eval tests.
  globalConfText = toINI { MKTXP = cfg.settings; };

  routerConfText = toINI (mapAttrs (_: r: r.settings) cfg.routers);

  # Target-system store derivations — referenced by BindReadOnlyPaths.
  globalConf = pkgs.writeText "_mktxp.conf" globalConfText;
  routerConf = pkgs.writeText "mktxp.conf" routerConfText;

  # ---------------------------------------------------------------------------
  # Router submodule type
  # ---------------------------------------------------------------------------
  # The outer submodule is reserved for future Nix-specific options (analogous
  # to how other NixOS modules add openFirewall, etc.). The inner settings
  # submodule carries the RFC-42 freeformType that maps directly to INI keys.
  # credentials_file and all other mktxp-native options live in .settings.
  routerSubmoduleType = types.submodule {
    options.settings = mkOption {
      type = types.submodule {
        freeformType =
          with types;
          attrsOf (
            nullOr (oneOf [
              bool
              int
              str
            ])
          );
      };
      default = { };
      description = ''
        RFC-42-conformant configuration: All keys map directly to
        router configuration options without additional checks.

        See the [upstream documentation](https://github.com/akpw/mktxp#configuration)
        for the full list.

        Credentials file path can be supplied with `credentials_file`.
      '';
    };
  };
in
{
  options.services.mktxp = {
    enable = mkEnableOption "mktxp, a Prometheus exporter for MikroTik RouterOS devices";

    package = mkPackageOption pkgs "mktxp" { };

    user = mkOption {
      type = types.str;
      default = "mktxp";
      description = "User account under which the mktxp service runs.";
    };

    group = mkOption {
      type = types.str;
      default = "mktxp";
      description = "Group account under which the mktxp service runs.";
    };

    settings = mkOption {
      type =
        with types;
        attrsOf (oneOf [
          bool
          int
          str
        ]);
      default = { };
      description = ''
        Global MKTXP settings.
        RFC-42-conformant configuration: Keys map directly to configuration
        options written to the `[MKTXP]` section of `_mktxp.conf` without
        additional checks.

        See the [upstream documentation](https://github.com/akpw/mktxp#configuration)
        for the full list.

        Notable options:
        - `listen` — socket address(es) to serve metrics on (default: `"0.0.0.0:49090"`)
        - `fetch_routers_in_parallel` — parallel scraping (default: `false`)
        - `verbose_mode` — debug logging (default: `false`)
      '';
      example = literalExpression ''
        {
          listen = "127.0.0.1:49090";
          fetch_routers_in_parallel = true;
          max_worker_threads = 10;
          verbose_mode = false;
        }
      '';
    };

    routers = mkOption {
      type = types.attrsOf routerSubmoduleType;
      default = { };
      description = ''
        Per-router configurations.
        Each attribute name becomes an INI section header in `mktxp.conf`
        (e.g. `routers."home-router"` → `[home-router]`).

        Default configuration applied to every router can be specified in
        {option}`services.mktxp.routers.default`, it's active unless overridden
        by the router's individual configuration
        {option}`services.mktxp.routers.<name>`.
        Written as the `[default]` section of `mktxp.conf`.
      '';
      example = literalExpression ''
        {
          default.settings = {
            health = true;
            bgp = false;
          };
          "home-router".settings = {
            credentials_file = config.sops.secrets."mktxp/home-router".path;
            hostname = "192.168.88.1";
            use_ssl = true;
            custom_labels = "site:home";
          };
          "office-router".settings = {
            credentials_file = config.sops.secrets."mktxp/office-router".path;
            hostname = "10.0.0.1";
            bgp = true;
            bfd = true;
          };
        }
      '';
    };

    # Internal options exposed for testing and external introspection.
    # Not part of the stable public API.
    #
    # *Text variants are plain Nix strings — host-portable and suitable for
    # eval tests running on any platform (e.g. macOS CI building Linux modules).
    # *File variants are target-system store derivations used by the service.
    _globalConfigText = mkOption {
      type = types.str;
      internal = true;
      readOnly = true;
      default = globalConfText;
      description = "INI text content of the generated `_mktxp.conf`.";
    };

    _routerConfigText = mkOption {
      type = types.str;
      internal = true;
      readOnly = true;
      default = routerConfText;
      description = "INI text content of the generated `mktxp.conf`.";
    };

    _globalConfigFile = mkOption {
      type = types.path;
      internal = true;
      readOnly = true;
      default = globalConf;
      description = "Store path of the generated `_mktxp.conf`.";
    };

    _routerConfigFile = mkOption {
      type = types.path;
      internal = true;
      readOnly = true;
      default = routerConf;
      description = "Store path of the generated `mktxp.conf`.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.routers != { };
        message = ''
          services.mktxp.routers must define at least one router entry.
          Add a router under services.mktxp.routers.<name>.settings.
        '';
      }
    ];

    services.mktxp.settings = {
      # workaround for `KeyError: 'compact_default_conf_values'`
      # compact_default_conf_values is always injected because mktxp's
      # _config_entry_reader does an unguarded as_bool() on this key,
      # crashing when it's absent
      compact_default_conf_values = lib.mkDefault false;
    };

    users.users = optionalAttrs (cfg.user == "mktxp") {
      mktxp = {
        isSystemUser = true;
        group = cfg.group;
        description = "mktxp Prometheus exporter service user";
      };
    };

    users.groups = optionalAttrs (cfg.group == "mktxp") {
      mktxp = { };
    };

    systemd.services.mktxp = {
      description = "mktxp Prometheus Exporter for MikroTik RouterOS";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # FileNotFoundError: 'which' crash
      # mktxp's argument parser unconditionally calls `which nano/vi/vim` to
      # detect the default editor, even when running `export`.  Without `which`
      # in PATH the Popen call raises FileNotFoundError and the service crashes
      # before it can start listening.
      path = [ pkgs.which ];

      environment = {
        # Python 3 buffers stdout when connected to a pipe (systemd journal).
        # Without this, print/logging output is silently swallowed and never
        # reaches journald even with verbose_mode = True.
        PYTHONUNBUFFERED = "1";
      };

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;

        # mktxp writes runtime state (DHCP cache, etc.) into its config
        # directory. The Nix-generated configs live immutably in the store;
        # BindReadOnlyPaths overlays them onto the mutable state directory so
        # mktxp can read them but cannot modify or replace them (EROFS on any
        # write attempt). systemd creates the target placeholders automatically
        # if they do not yet exist.
        StateDirectory = "mktxp";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/mktxp";

        BindReadOnlyPaths = [
          "${globalConf}:/var/lib/mktxp/_mktxp.conf"
          "${routerConf}:/var/lib/mktxp/mktxp.conf"
        ];

        ExecStart = "${lib.getExe cfg.package} --cfg-dir /var/lib/mktxp export";

        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStartSec = "60s";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        # ProtectSystem=strict: systemd keeps StateDirectory writable while
        # BindReadOnlyPaths enforces immutability on the two config files.
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectHostname = true;
        ProtectClock = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          # AF_UNIX is needed for Python's internal socket handling.
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        CapabilityBoundingSet = "";
      };
    };
  };
}

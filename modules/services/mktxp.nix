# NixOS module for mktxp — Prometheus Exporter for MikroTik RouterOS devices
# https://github.com/akpw/mktxp
#
# RFC-42 is followed: freeformType lets users pass any upstream option through
# without this module needing to redeclare and maintain every known key.
# Only the Nix-specific credentialsFile option is explicitly declared.
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
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    optionalAttrs
    types
    ;

  # ---------------------------------------------------------------------------
  # INI generation helpers
  # ---------------------------------------------------------------------------
  # mktxp uses configobj, which reads Python-style literals.

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

  # Render an attrset as 4-space-indented INI key = value lines.
  # Input values must be bool, int, str, or null.
  renderSection =
    attrs: lib.concatStringsSep "\n" (mapAttrsToList (k: v: "    ${k} = ${toConfValue v}") attrs);

  # Build the INI attrset for a router section.
  # Strips the Nix-only credentialsFile and, when set, injects credentials_file.
  routerToAttrs =
    rcfg:
    (builtins.removeAttrs rcfg [ "credentialsFile" ])
    // optionalAttrs (rcfg.credentialsFile != null) {
      credentials_file = toString rcfg.credentialsFile;
    };

  # Plain Nix strings for the generated configs.
  # Exposed via _globalConfigText / _routerConfigText for host-portable testing
  # (the pkgs.writeText calls below are target-system derivations; tests use
  # the strings directly so they build on any host).
  globalConfText = ''
    [MKTXP]
    ${renderSection cfg.settings}
  '';

  routerConfText = lib.concatStringsSep "\n\n" (
    mapAttrsToList (name: attrs: "[${name}]\n${renderSection attrs}") (
      { default = routerToAttrs cfg.defaultRouterSettings; } // mapAttrs (_: routerToAttrs) cfg.routers
    )
  );

  # _mktxp.conf — global [MKTXP] settings
  globalConf = pkgs.writeText "_mktxp.conf" globalConfText;

  # mktxp.conf — [default] section followed by per-router sections
  routerConf = pkgs.writeText "mktxp.conf" routerConfText;

  # Setup script body as a pure string (store paths stripped via
  # unsafeDiscardStringContext) so eval tests can inspect it on any host
  # without building target-system derivations.
  setupScriptText = builtins.unsafeDiscardStringContext ''
    ln -sf ${globalConf} /var/lib/mktxp/_mktxp.conf
    ln -sf ${routerConf} /var/lib/mktxp/mktxp.conf
  '';

  # ---------------------------------------------------------------------------
  # Router submodule type
  # ---------------------------------------------------------------------------
  # credentialsFile is the only Nix-specific (non-INI) option.
  # All other router settings are passed through via freeformType (RFC-42).
  routerSubmoduleType = types.submodule {
    freeformType =
      with types;
      attrsOf (
        nullOr (oneOf [
          bool
          int
          str
        ])
      );

    options = {
      credentialsFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a YAML file providing `username` and `password` for this router.
          Takes precedence over the `username` and `password` keys set directly
          in the router configuration. Intended for use with secret management
          tools such as [sops-nix](https://github.com/Mic92/sops-nix) or
          [agenix](https://github.com/ryantm/agenix).

          The file must be readable by the service user
          ({option}`services.mktxp.user`) and must be valid YAML:

          ```yaml
          username: monitoring
          password: s3cr3t
          ```
        '';
        example = literalExpression ''config.sops.secrets."mktxp/my-router".path'';
      };
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
        Global MKTXP settings written to the `[MKTXP]` section of `_mktxp.conf`.
        Keys map directly to mktxp configuration options; see the
        [upstream documentation](https://github.com/akpw/mktxp#configuration)
        for the full list. Notable options:

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

    defaultRouterSettings = mkOption {
      type = routerSubmoduleType;
      default = { };
      description = ''
        Default settings applied to every router unless overridden in
        {option}`services.mktxp.routers`. Written as the `[default]` section of
        `mktxp.conf`. Keys map directly to mktxp router configuration options.

        ::: {.note}
        Prefer per-router {option}`credentialsFile` entries over placing
        credentials in shared defaults.
        :::
      '';
    };

    routers = mkOption {
      type = types.attrsOf routerSubmoduleType;
      default = { };
      description = ''
        Per-router configurations. Each attribute name becomes an INI section
        header in `mktxp.conf` (e.g. `routers."home-router"` → `[home-router]`).
        Keys map directly to mktxp router configuration options and override
        {option}`defaultRouterSettings` for that router.

        To supply credentials via [sops-nix](https://github.com/Mic92/sops-nix) or
        [agenix](https://github.com/ryantm/agenix):

        ```nix
        sops.secrets."mktxp/home-router".owner = config.services.mktxp.user;
        services.mktxp.routers."home-router".credentialsFile =
          config.sops.secrets."mktxp/home-router".path;
        ```
      '';
      example = literalExpression ''
        {
          "home-router" = {
            credentialsFile = config.sops.secrets."mktxp/home-router".path;
            hostname = "192.168.88.1";
            use_ssl = true;
            custom_labels = "site:home";
          };
          "office-router" = {
            credentialsFile = config.sops.secrets."mktxp/office-router".path;
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

    _setupScriptText = mkOption {
      type = types.str;
      internal = true;
      readOnly = true;
      default = setupScriptText;
      description = ''
        Body of the `ExecStartPre` symlink-setup script with store path references
        stripped (`builtins.unsafeDiscardStringContext`). Suitable for verifying
        the setup command pattern in host-portable eval tests.
      '';
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
          Add a router under services.mktxp.routers.<name>.
        '';
      }
    ];

    users.users = lib.optionalAttrs (cfg.user == "mktxp") {
      mktxp = {
        isSystemUser = true;
        group = cfg.group;
        description = "mktxp Prometheus exporter service user";
      };
    };

    users.groups = lib.optionalAttrs (cfg.group == "mktxp") {
      mktxp = { };
    };

    systemd.services.mktxp = {
      description = "mktxp Prometheus Exporter for MikroTik RouterOS";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;

        # mktxp writes runtime state (DHCP cache, etc.) alongside its config.
        # We keep the Nix-generated configs immutable in the store and symlink
        # them from the writable state directory. Updating a NixOS generation
        # re-runs ExecStartPre, which updates the symlinks atomically.
        StateDirectory = "mktxp";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/mktxp";

        ExecStartPre =
          let
            setupScript = pkgs.writeShellScript "mktxp-setup-config" ''
              ln -sf ${globalConf} /var/lib/mktxp/_mktxp.conf
              ln -sf ${routerConf} /var/lib/mktxp/mktxp.conf
            '';
          in
          "${setupScript}";

        ExecStart = "${lib.getExe cfg.package} --cfg-dir /var/lib/mktxp export";

        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStartSec = "60s";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        # ProtectSystem=strict: systemd automatically keeps StateDirectory writable.
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

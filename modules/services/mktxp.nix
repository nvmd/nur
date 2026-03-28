# NixOS module for mktxp — Prometheus Exporter for MikroTik RouterOS devices
# https://github.com/akpw/mktxp
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

  # Render a set of key-value pairs as 4-space-indented INI lines.
  # Values are converted with toConfValue before interpolation,
  # so the input attrset may contain raw Nix bool/int/str/null values.
  renderSection =
    attrs: lib.concatStringsSep "\n" (mapAttrsToList (k: v: "    ${k} = ${toConfValue v}") attrs);

  # Build the attrset that represents one INI section.
  # Merges the evaluated settings with the optional credentials_file path.
  routerToAttrs =
    rcfg:
    rcfg.settings
    // optionalAttrs (rcfg.credentialsFile != null) {
      credentials_file = toString rcfg.credentialsFile;
    };

  # _mktxp.conf — global [MKTXP] settings
  globalConf = pkgs.writeText "_mktxp.conf" ''
    [MKTXP]
    ${renderSection cfg.settings}
  '';

  # mktxp.conf — [default] section followed by per-router sections
  routerConf = pkgs.writeText "mktxp.conf" (
    lib.concatStringsSep "\n\n" (
      mapAttrsToList (name: attrs: "[${name}]\n${renderSection attrs}") (
        { default = routerToAttrs cfg.defaultRouterSettings; } // mapAttrs (_: routerToAttrs) cfg.routers
      )
    )
  );

  # ---------------------------------------------------------------------------
  # Router submodule type
  # ---------------------------------------------------------------------------
  # RFC-42: freeformType lets users pass undocumented options through;
  # the declared options document and type-check the common ones.

  routerSettingsType = types.submodule {
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
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Enable metrics collection for this router.";
      };

      module_only = mkOption {
        type = types.bool;
        default = false;
        description = "Use this entry only as a probe-module target; skip `/metrics` collection.";
      };

      hostname = mkOption {
        type = types.str;
        default = "localhost";
        description = "RouterOS device hostname or IP address.";
      };

      port = mkOption {
        type = types.port;
        default = 8728;
        description = "RouterOS API port.";
      };

      username = mkOption {
        type = types.str;
        default = "";
        description = ''
          RouterOS username. The account requires `api` and `read` permission policies.
          Prefer {option}`credentialsFile` to avoid storing credentials in the Nix store.
        '';
      };

      password = mkOption {
        type = types.str;
        default = "";
        description = ''
          RouterOS password.

          ::: {.warning}
          This value is stored in the world-readable Nix store.
          Use {option}`credentialsFile` for production deployments instead.
          :::
        '';
      };

      custom_labels = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Comma-separated `key:value` (or `key=value`) labels injected into all
          device metrics, e.g. `site:office,env:prod`. `null` disables custom labels.
        '';
        example = "site:home,role:router";
      };

      use_ssl = mkOption {
        type = types.bool;
        default = false;
        description = "Connect to RouterOS via the API-SSL service.";
      };

      no_ssl_certificate = mkOption {
        type = types.bool;
        default = false;
        description = "Allow API-SSL connections without a router SSL certificate.";
      };

      ssl_certificate_verify = mkOption {
        type = types.bool;
        default = false;
        description = "Verify the RouterOS SSL certificate.";
      };

      ssl_check_hostname = mkOption {
        type = types.bool;
        default = true;
        description = "Verify that the hostname matches the peer certificate's hostname.";
      };

      ssl_ca_file = mkOption {
        type = types.str;
        default = "";
        description = "Path to a CA certificate file for SSL validation. Empty string uses the system CA store.";
      };

      plaintext_login = mkOption {
        type = types.bool;
        default = true;
        description = "Use plaintext login. Set to `false` for RouterOS versions older than 6.43.";
      };

      # -- Metric collectors --------------------------------------------------

      health = mkOption {
        type = types.bool;
        default = true;
        description = "System health metrics.";
      };

      installed_packages = mkOption {
        type = types.bool;
        default = true;
        description = "Installed packages metrics.";
      };

      dhcp = mkOption {
        type = types.bool;
        default = true;
        description = "DHCP general metrics.";
      };

      dhcp_lease = mkOption {
        type = types.bool;
        default = true;
        description = "DHCP lease metrics.";
      };

      connections = mkOption {
        type = types.bool;
        default = true;
        description = "IP connections metrics.";
      };

      connection_stats = mkOption {
        type = types.bool;
        default = false;
        description = "Open IP connections metrics.";
      };

      interface = mkOption {
        type = types.bool;
        default = true;
        description = "Interface traffic metrics.";
      };

      route = mkOption {
        type = types.bool;
        default = true;
        description = "IPv4 route metrics.";
      };

      pool = mkOption {
        type = types.bool;
        default = true;
        description = "IPv4 address pool metrics.";
      };

      firewall = mkOption {
        type = types.bool;
        default = true;
        description = "IPv4 firewall rule traffic metrics.";
      };

      neighbor = mkOption {
        type = types.bool;
        default = true;
        description = "IPv4 reachable-neighbour metrics.";
      };

      address_list = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Firewall Address List metrics. Comma-separated list of address list names to
          export, or `null` to disable.
        '';
        example = "blacklist,whitelist";
      };

      dns = mkOption {
        type = types.bool;
        default = false;
        description = "DNS statistics.";
      };

      ipv6_route = mkOption {
        type = types.bool;
        default = false;
        description = "IPv6 route metrics.";
      };

      ipv6_pool = mkOption {
        type = types.bool;
        default = false;
        description = "IPv6 address pool metrics.";
      };

      ipv6_firewall = mkOption {
        type = types.bool;
        default = false;
        description = "IPv6 firewall rule traffic metrics.";
      };

      ipv6_neighbor = mkOption {
        type = types.bool;
        default = false;
        description = "IPv6 reachable-neighbour metrics.";
      };

      ipv6_address_list = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          IPv6 Firewall Address List metrics. Comma-separated list of address list names,
          or `null` to disable.
        '';
      };

      poe = mkOption {
        type = types.bool;
        default = true;
        description = "PoE power metrics.";
      };

      monitor = mkOption {
        type = types.bool;
        default = true;
        description = "Interface monitor metrics.";
      };

      netwatch = mkOption {
        type = types.bool;
        default = true;
        description = "Netwatch probe metrics.";
      };

      public_ip = mkOption {
        type = types.bool;
        default = true;
        description = "Public IP metrics.";
      };

      wireless = mkOption {
        type = types.bool;
        default = true;
        description = "WLAN general metrics.";
      };

      wireless_clients = mkOption {
        type = types.bool;
        default = true;
        description = "WLAN client metrics.";
      };

      capsman = mkOption {
        type = types.bool;
        default = true;
        description = "CAPsMAN general metrics.";
      };

      capsman_clients = mkOption {
        type = types.bool;
        default = true;
        description = "CAPsMAN client metrics.";
      };

      w60g = mkOption {
        type = types.bool;
        default = false;
        description = "W60G wireless bridge metrics.";
      };

      eoip = mkOption {
        type = types.bool;
        default = false;
        description = "EoIP tunnel status metrics.";
      };

      gre = mkOption {
        type = types.bool;
        default = false;
        description = "GRE tunnel status metrics.";
      };

      ipip = mkOption {
        type = types.bool;
        default = false;
        description = "IPIP tunnel status metrics.";
      };

      lte = mkOption {
        type = types.bool;
        default = false;
        description = ''
          LTE signal and status metrics.
          Requires the `test` permission policy on RouterOS v6.
        '';
      };

      ipsec = mkOption {
        type = types.bool;
        default = false;
        description = "IPsec active-peer metrics.";
      };

      switch_port = mkOption {
        type = types.bool;
        default = false;
        description = "Switch port metrics.";
      };

      kid_control_assigned = mkOption {
        type = types.bool;
        default = false;
        description = "Kid Control metrics for connected devices with assigned users.";
      };

      kid_control_dynamic = mkOption {
        type = types.bool;
        default = false;
        description = "Kid Control metrics for all connected devices, including those without an assigned user.";
      };

      user = mkOption {
        type = types.bool;
        default = true;
        description = "Active-user metrics.";
      };

      queue = mkOption {
        type = types.bool;
        default = true;
        description = "Queue metrics.";
      };

      bfd = mkOption {
        type = types.bool;
        default = false;
        description = "BFD session metrics.";
      };

      bgp = mkOption {
        type = types.bool;
        default = false;
        description = "BGP session metrics.";
      };

      routing_stats = mkOption {
        type = types.bool;
        default = false;
        description = "Routing process statistics.";
      };

      certificate = mkOption {
        type = types.bool;
        default = false;
        description = "Certificate metrics.";
      };

      container = mkOption {
        type = types.bool;
        default = false;
        description = "Container metrics.";
      };

      # -- Cross-router references --------------------------------------------

      remote_dhcp_entry = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Name of another mktxp router entry to use for remote DHCP resolution.
          Must match an attribute name in {option}`services.mktxp.routers`.
        '';
      };

      remote_capsman_entry = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Name of another mktxp router entry to use for remote CAPsMAN information.
          Must match an attribute name in {option}`services.mktxp.routers`.
        '';
      };

      # -- Display options ----------------------------------------------------

      interface_name_format = mkOption {
        type = types.enum [
          "name"
          "comment"
          "combined"
        ];
        default = "name";
        description = ''
          Format for interface and resource names used in metric labels.

          - `name` — interface name only (e.g. `ether1`)
          - `comment` — interface comment if set, falling back to name
          - `combined` — both name and comment (e.g. `ether1 (Office Switch)`)
        '';
      };

      check_for_updates = mkOption {
        type = types.bool;
        default = false;
        description = "Check for available RouterOS software updates.";
      };
    };
  };

  # Wrapper submodule that adds the secrets-safe credentialsFile option
  # alongside the INI-serialisable settings.
  routerSubmoduleType = types.submodule {
    options = {
      credentialsFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a YAML file that provides `username` and `password` for this router.
          Takes precedence over {option}`settings.username` and
          {option}`settings.password`. Intended for use with secret management tools
          such as [sops-nix](https://github.com/Mic92/sops-nix) or
          [agenix](https://github.com/ryantm/agenix).

          The file must be readable by the service user
          ({option}`services.mktxp.user`) and must be valid YAML, for example:

          ```yaml
          username: monitoring
          password: s3cr3t
          ```
        '';
        example = literalExpression ''config.sops.secrets."mktxp/my-router".path'';
      };

      settings = mkOption {
        type = routerSettingsType;
        default = { };
        description = ''
          Per-router configuration values. All documented options correspond
          directly to keys in `mktxp.conf`; any undocumented key is passed
          through as-is via the freeform type (RFC 42).
        '';
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
      default = { };
      description = ''
        Global MKTXP settings, written to the `[MKTXP]` section of `_mktxp.conf`.
        Controls the HTTP listener, connection pool behaviour, and scrape parameters.
        Undocumented keys are passed through as-is via the freeform type (RFC 42).

        See the [upstream documentation](https://github.com/akpw/mktxp#configuration)
        for the full list of available options.
      '';
      type = types.submodule {
        freeformType =
          with types;
          attrsOf (oneOf [
            bool
            int
            str
          ]);

        options = {
          listen = mkOption {
            type = types.str;
            default = "0.0.0.0:49090";
            description = ''
              Space-separated list of socket addresses to listen on.
              Both IPv4 and IPv6 addresses are supported.
            '';
            example = "127.0.0.1:49090 [::1]:49090";
          };

          socket_timeout = mkOption {
            type = types.int;
            default = 5;
            description = "RouterOS API socket timeout in seconds.";
          };

          initial_delay_on_failure = mkOption {
            type = types.int;
            default = 120;
            description = "Initial delay in seconds before the first retry after a connection failure.";
          };

          max_delay_on_failure = mkOption {
            type = types.int;
            default = 900;
            description = "Maximum retry delay in seconds after repeated failures.";
          };

          delay_inc_div = mkOption {
            type = types.int;
            default = 5;
            description = "Divisor used to compute the delay increment between retries.";
          };

          bandwidth = mkOption {
            type = types.bool;
            default = false;
            description = "Enable bandwidth metrics collection.";
          };

          bandwidth_test_dns_server = mkOption {
            type = types.str;
            default = "8.8.8.8";
            description = "DNS server used for the bandwidth-test connectivity check.";
          };

          bandwidth_test_interval = mkOption {
            type = types.int;
            default = 600;
            description = "Interval in seconds between bandwidth metric collections.";
          };

          minimal_collect_interval = mkOption {
            type = types.int;
            default = 5;
            description = "Minimum metric collection interval in seconds.";
          };

          verbose_mode = mkOption {
            type = types.bool;
            default = false;
            description = "Enable verbose logging for troubleshooting.";
          };

          fetch_routers_in_parallel = mkOption {
            type = types.bool;
            default = false;
            description = "Fetch metrics from all routers in parallel instead of sequentially.";
          };

          max_worker_threads = mkOption {
            type = types.int;
            default = 5;
            description = "Maximum number of worker threads used for parallel router fetching.";
          };

          max_scrape_duration = mkOption {
            type = types.int;
            default = 30;
            description = "Maximum per-router scrape duration in seconds (parallel mode only).";
          };

          total_max_scrape_duration = mkOption {
            type = types.int;
            default = 90;
            description = "Maximum total scrape duration across all routers in seconds (parallel mode only).";
          };

          http_server_threads = mkOption {
            type = types.int;
            default = 16;
            description = "Number of HTTP server worker threads.";
          };

          persistent_router_connection_pool = mkOption {
            type = types.bool;
            default = true;
            description = "Reuse router API connections between scrapes.";
          };

          persistent_dhcp_cache = mkOption {
            type = types.bool;
            default = true;
            description = "Persist the DHCP data cache between metric collections.";
          };

          compact_default_conf_values = mkOption {
            type = types.bool;
            default = false;
            description = "Write only router-specific overrides to `mktxp.conf`, omitting values that match defaults.";
          };

          prometheus_headers_deduplication = mkOption {
            type = types.bool;
            default = false;
            description = "Deduplicate Prometheus `HELP`/`TYPE` header lines in the metrics output.";
          };

          probe_connection_pool = mkOption {
            type = types.bool;
            default = false;
            description = "Enable connection reuse for probe-mode requests, keyed by module and target.";
          };

          probe_connection_pool_ttl = mkOption {
            type = types.int;
            default = 300;
            description = "Time-to-live in seconds for entries in the probe connection pool.";
          };

          probe_connection_pool_max_size = mkOption {
            type = types.int;
            default = 128;
            description = "Maximum number of connections kept in the probe connection pool.";
          };
        };
      };
    };

    defaultRouterSettings = mkOption {
      default = { };
      description = ''
        Default settings applied to every router unless overridden in
        {option}`services.mktxp.routers`. Written as the `[default]` section
        of `mktxp.conf`.

        ::: {.note}
        Avoid setting `credentialsFile` or passwords here; prefer per-router
        credentials so that each router uses its own secret.
        :::
      '';
      type = routerSubmoduleType;
    };

    routers = mkOption {
      default = { };
      description = ''
        Per-router configurations. Each attribute name becomes an INI section
        header in `mktxp.conf` (e.g. `routers."home-router"` → `[home-router]`).
        Settings here override {option}`defaultRouterSettings` for that router.

        To supply credentials via [sops-nix](https://github.com/Mic92/sops-nix)
        or [agenix](https://github.com/ryantm/agenix), set `credentialsFile` to
        the path of a secrets-managed YAML file:

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
            settings = {
              hostname = "192.168.88.1";
              use_ssl = true;
              custom_labels = "site:home";
            };
          };
          "office-router" = {
            credentialsFile = config.sops.secrets."mktxp/office-router".path;
            settings = {
              hostname = "10.0.0.1";
              bgp = true;
              bfd = true;
              custom_labels = "site:office";
            };
          };
        }
      '';
      type = types.attrsOf routerSubmoduleType;
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

        # A persistent state directory is required because mktxp caches DHCP
        # data between scrapes (persistent_dhcp_cache) and because the config
        # files must be writable by the process (configobj may rewrite them).
        StateDirectory = "mktxp";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/mktxp";

        # Copy Nix-store-generated configs into the writable state directory
        # on every start so that NixOS rebuilds are reflected immediately.
        ExecStartPre =
          let
            setupScript = pkgs.writeShellScript "mktxp-setup-config" ''
              cp --no-preserve=all ${globalConf} /var/lib/mktxp/_mktxp.conf
              cp --no-preserve=all ${routerConf} /var/lib/mktxp/mktxp.conf
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
        # ProtectSystem=strict combined with StateDirectory: systemd automatically
        # bind-mounts /var/lib/mktxp as writable despite the strict setting.
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
          # AF_UNIX is needed for Python's internal socket usage.
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

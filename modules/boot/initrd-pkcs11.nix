{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.boot.initrd.systemd.pkcs11;
  initrdSystemdCfg = config.boot.initrd.systemd;

  # Build a pluginEnv for pcscd in the initrd, following the same pattern
  # as nixos/modules/services/hardware/pcscd.nix
  pluginEnv = pkgs.buildEnv {
    name = "pcscd-initrd-plugins";
    paths = map (p: "${p}/pcsc/drivers") cfg.pcscd.plugins;
  };

  # Empty reader.conf — pcscd auto-detects hotplug CCID readers, so no
  # static reader configuration is needed.
  readerConf = pkgs.writeText "reader.conf" "";
in
{
  options.boot.initrd.systemd.pkcs11 = {
    enable = lib.mkEnableOption "PKCS#11 smartcard support for LUKS unlock in systemd initrd";

    modules = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        ykcs11 = "${pkgs.yubico-piv-tool}/lib/libykcs11.so";
      };
      defaultText = lib.literalExpression ''
        {
          ykcs11 = "''${pkgs.yubico-piv-tool}/lib/libykcs11.so";
        }
      '';
      example = lib.literalExpression ''
        {
          ykcs11 = "''${pkgs.yubico-piv-tool}/lib/libykcs11.so";
          opensc = "''${pkgs.opensc}/lib/opensc-pkcs11.so";
        }
      '';
      description = ''
        PKCS#11 modules to make available in the initrd.  Each attribute
        name becomes a p11-kit module file at
        `/etc/pkcs11/modules/<name>.module`, and each value is the
        absolute Nix store path to the `.so` library.

        Multiple modules can be specified to support smartcards from
        different vendors simultaneously.
      '';
    };

    pcscd = {
      plugins = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ pkgs.ccid ];
        defaultText = lib.literalExpression "[ pkgs.ccid ]";
        description = ''
          Smartcard reader driver packages for pcscd.
          The default `ccid` covers USB CCID-class readers including
          YubiKeys.
        '';
      };
    };
  };

  config = lib.mkIf (initrdSystemdCfg.enable && cfg.enable) {
    assertions = [
      {
        assertion = config.boot.initrd.systemd.enable;
        message = ''
          boot.initrd.systemd.pkcs11 requires a systemd-based initrd
          (boot.initrd.systemd.enable = true).
        '';
      }
    ];

    # --- Store paths ---
    # make-initrd-ng automatically follows direct ELF shared-library
    # dependencies, so transitive .so deps of the token plugin (like
    # libp11-kit) are pulled in.  However, dlopen'd libraries (the PKCS#11
    # module loaded by p11-kit at runtime via config file) must be listed
    # explicitly.
    boot.initrd.systemd.storePaths =
      [
        # The cryptsetup token plugin shipped with systemd
        "${initrdSystemdCfg.package}/lib/cryptsetup/libcryptsetup-token-systemd-pkcs11.so"

        # pcscd binary + CCID drivers
        "${pkgs.pcsclite}/bin/pcscd"
        pluginEnv
      ]
      # Each PKCS#11 .so is dlopen'd by p11-kit — not auto-detected by
      # make-initrd-ng, so must be listed explicitly.
      ++ lib.attrValues cfg.modules;

    # --- p11-kit module registration ---
    # p11-kit discovers modules via files in /etc/pkcs11/modules/.
    boot.initrd.systemd.contents =
      lib.mapAttrs'
        (name: soPath:
          lib.nameValuePair "/etc/pkcs11/modules/${name}.module" {
            text = ''
              module: ${soPath}
            '';
          }
        )
        cfg.modules
      // {
        # pcscd expects a reader.conf even if empty.
        "/etc/reader.conf".source = readerConf;
      };

    # --- pcscd socket + service in initrd ---
    # pcscd is socket-activated.  We need both the socket and the service
    # available *before* cryptsetup tries to open LUKS volumes.
    #
    # Using the NixOS `sockets` option (not raw `units`) so that
    # `wantedBy` creates proper `.wants/` symlinks at build time —
    # raw [Install] WantedBy= in unit text does nothing in the initrd
    # because there is no `systemctl enable` during image assembly.
    #
    # DefaultDependencies=no avoids the implicit After=sysinit.target
    # ordering that would otherwise make the socket start too late.
    boot.initrd.systemd.sockets.pcscd = {
      wantedBy = [ "cryptsetup-pre.target" ];
      unitConfig = {
        Description = "PC/SC Smart Card Daemon Socket (initrd)";
        DefaultDependencies = false;
        Before = [ "cryptsetup-pre.target" ];
      };
      listenStreams = [ "/run/pcscd/pcscd.comm" ];
      socketConfig.SocketMode = "0666";
    };

    boot.initrd.systemd.services.pcscd = {
      description = "PC/SC Smart Card Daemon (initrd)";
      after = [ "pcscd.socket" ];
      before = [ "cryptsetup-pre.target" ];
      unitConfig = {
        DefaultDependencies = false;
      };
      serviceConfig = {
        # -f (--foreground): don't daemonize, log to stderr
        # -x (--auto-exit): quit after 60s of inactivity once the last
        #    PC/SC context is released — desirable in initrd so pcscd
        #    doesn't linger after LUKS unlock / switch-root
        # -c (--config): explicit config path prevents pcscd from
        #    scanning all of /etc looking for reader.conf (nixpkgs#121088)
        ExecStart = "${pkgs.pcsclite}/bin/pcscd -f -x -c ${readerConf}";
        Type = "simple";
      };
      environment = {
        PCSCLITE_HP_DROPDIR = pluginEnv;
      };
    };

    # --- Kernel modules for USB smartcard readers ---
    # Note: "ccid" is a userspace pcscd driver (pkgs.ccid), NOT a kernel
    # module — it is handled via pluginEnv / PCSCLITE_HP_DROPDIR above.
    boot.initrd.availableKernelModules = [
      "usbhid"
      "xhci_pci"
      "xhci_hcd"
      "ehci_pci"
      "ehci_hcd"
    ];
  };
}

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

  # reader.conf — empty by default (pcscd auto-detects hotplug CCID readers
  # via PCSCLITE_HP_DROPDIR); populated when pcscd.readerConf is set (e.g.
  # for virtual/serial readers like vsmartcard-vpcd).
  readerConf = pkgs.writeText "reader.conf" cfg.pcscd.readerConf;
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
          YubiKeys.  These are hotplug drivers discovered via
          `PCSCLITE_HP_DROPDIR`.

          For non-hotplug (serial/virtual) readers such as
          `vsmartcard-vpcd`, use `pcscd.readerConf` instead.
        '';
      };

      readerConf = lib.mkOption {
        type = lib.types.lines;
        default = "";
        example = lib.literalExpression ''
          '''
            FRIENDLYNAME "Virtual PCD"
            DEVICENAME   /dev/null:0x8C4B
            LIBPATH      ''${pkgs.vsmartcard-vpcd}/var/lib/pcsc/drivers/serial/libifdvpcd.so
            CHANNELID    0x8C4B
          '''
        '';
        description = ''
          Additional content for pcscd's `reader.conf` in the initrd.

          Used for non-hotplug (serial/virtual) readers that are not
          discovered via udev.  Each entry follows the
          {manpage}`reader.conf(5)` format:

          ```
          FRIENDLYNAME "<name>"
          DEVICENAME   <address>
          LIBPATH      <path-to-ifd-handler.so>
          CHANNELID    <channel>
          ```

          Hotplug USB readers (e.g. YubiKey CCID) are configured
          automatically via `pcscd.plugins` — this option is only
          needed for virtual or serial readers.

          Any library referenced by LIBPATH must also be added to
          `boot.initrd.systemd.storePaths`.
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

    # Warn when LUKS devices are configured but none have pkcs11-uri= in
    # crypttabExtraOpts — systemd-cryptsetup only tries the token path when
    # the crypttab entry carries pkcs11-uri=auto (or an explicit URI), exactly
    # like TPM2 requires tpm2-device=auto.  Without it the token is silently
    # ignored and the volume falls back to passphrase prompt.
    warnings = lib.optional (
      config.boot.initrd.luks.devices != { }
      && !(lib.any
        (device: lib.any (opt: lib.hasPrefix "pkcs11-uri=" opt) device.crypttabExtraOpts)
        (lib.attrValues config.boot.initrd.luks.devices))
    ) ''
      boot.initrd.systemd.pkcs11 is enabled, but none of the configured LUKS
      devices have a 'pkcs11-uri=' option in crypttabExtraOpts.
      systemd-cryptsetup will not attempt PKCS#11 token unlock.
      Add the following to each volume you want unlocked via a PKCS#11 token:

        boot.initrd.luks.devices."<name>".crypttabExtraOpts =
          [ "pkcs11-uri=auto" "token-timeout=30" ];
    '';

    # --- Store paths ---
    # make-initrd-ng follows direct ELF shared-library dependencies but
    # NOT libraries loaded via dlopen() at runtime.  Both the systemd
    # PKCS#11 token plugin and the PKCS#11 modules themselves are
    # dlopen'd, so they must be listed explicitly.
    boot.initrd.systemd.storePaths =
      [
        # The cryptsetup token plugin shipped with systemd.
        # It dlopen's libp11-kit.so.0 at runtime to enumerate PKCS#11
        # modules, so p11-kit must also be listed explicitly.
        "${initrdSystemdCfg.package}/lib/cryptsetup/libcryptsetup-token-systemd-pkcs11.so"
        "${pkgs.p11-kit}/lib/libp11-kit.so.0"

        # p11-kit-trust provides the trust-policy module and is
        # dlopen'd by libp11-kit at runtime.
        "${pkgs.p11-kit}/lib/pkcs11/p11-kit-trust.so"

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
      # Requires + after matches the upstream pcscd.service unit shipped
      # by the pcsclite project.
      requires = [ "pcscd.socket" ];
      after = [ "pcscd.socket" ];
      # Start pcscd eagerly so it has time to probe the reader before
      # systemd-cryptsetup connects via libpcsclite.  Socket activation
      # alone would start pcscd only when the first client connects,
      # which creates a race with reader enumeration.
      wantedBy = [ "cryptsetup-pre.target" ];
      before = [
        "cryptsetup-pre.target"
        # Clean shutdown before switch-root — following the pattern
        # from initrd-ssh.nix and clevis in luksroot.nix.
        "initrd-switch-root.target"
        "shutdown.target"
      ];
      conflicts = [
        "initrd-switch-root.target"
        "shutdown.target"
      ];
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
    # Force-loaded (not just available) so that the USB host controller and HID
    # driver are present before pcscd probes for readers — even on systems where
    # the root FS is on NVMe/SATA and nothing else triggers xhci udev autoload.
    # Note: "ccid" is a userspace pcscd driver (pkgs.ccid), NOT a kernel
    # module — it is handled via pluginEnv / PCSCLITE_HP_DROPDIR above.
    boot.initrd.kernelModules = [
      "usbhid"
      "xhci_pci"
      "xhci_hcd"
      "ehci_pci"
      "ehci_hcd"
    ];
  };
}

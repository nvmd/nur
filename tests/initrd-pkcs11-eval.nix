# Non-VM module evaluation tests for the initrd-pkcs11 NixOS module.
#
# Same approach as mktxp-eval.nix: all assertions are evaluated at Nix eval
# time.  Failed assertions throw immediately; `nix flake check` reports them
# as evaluation errors.
{
  pkgs,
  nixpkgsLib,
  initrdPkcs11Module,
}:
let
  lib = nixpkgsLib;

  # Evaluate the initrd-pkcs11 module with an extra config attrset.
  evalPkcs11 =
    extraConfig:
    lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        initrdPkcs11Module
        extraConfig
        {
          # Minimal required options for NixOS evaluation.
          fileSystems."/" = {
            device = "/dev/sda1";
            fsType = "ext4";
          };
          boot.loader.grub.device = "/dev/sda";
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "24.11";
        }
      ];
    };

  assertEval =
    name: checks:
    builtins.seq
      (builtins.all lib.id checks)
      (pkgs.runCommandLocal "initrd-pkcs11-eval-${name}" { } "touch $out");

  # Helper: extract source paths from storePaths submodules.
  storePathSources = cfg: map (p: "${p.source}") cfg.boot.initrd.systemd.storePaths;

  # ---------------------------------------------------------------------------
  # Scenario A: module enabled with defaults (YubiKey PIV)
  # ---------------------------------------------------------------------------
  scenarioA = evalPkcs11 {
    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.pkcs11.enable = true;
  };

  # ---------------------------------------------------------------------------
  # Scenario B: module disabled — config should be absent
  # ---------------------------------------------------------------------------
  scenarioB = evalPkcs11 {
    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.pkcs11.enable = false;
  };

  # ---------------------------------------------------------------------------
  # Scenario C: multiple PKCS#11 modules (YubiKey + OpenSC)
  # ---------------------------------------------------------------------------
  scenarioC = evalPkcs11 {
    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.pkcs11 = {
      enable = true;
      modules = {
        ykcs11 = "${pkgs.yubico-piv-tool}/lib/libykcs11.so";
        opensc = "${pkgs.opensc}/lib/opensc-pkcs11.so";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Scenario D: pkcs11 enabled, LUKS device configured but NO pkcs11-uri=
  # Expected: a NixOS warning fires reminding the user to add pkcs11-uri=auto.
  # ---------------------------------------------------------------------------
  scenarioD = evalPkcs11 {
    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.pkcs11.enable = true;
    boot.initrd.luks.devices.cryptroot = {
      device = "/dev/sda2";
      # crypttabExtraOpts intentionally omitted — warning should fire
    };
  };

  # ---------------------------------------------------------------------------
  # Scenario E: pkcs11 enabled, LUKS device with pkcs11-uri=auto set correctly
  # Expected: no warning.
  # ---------------------------------------------------------------------------
  scenarioE = evalPkcs11 {
    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.pkcs11.enable = true;
    boot.initrd.luks.devices.cryptroot = {
      device = "/dev/sda2";
      crypttabExtraOpts = [ "pkcs11-uri=auto" "token-timeout=30" ];
    };
  };

  # ---------------------------------------------------------------------------
  # Scenario F: pcscd.readerConf set — content must appear in reader.conf
  # ---------------------------------------------------------------------------
  scenarioF = evalPkcs11 {
    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.pkcs11.enable = true;
    boot.initrd.systemd.pkcs11.pcscd.readerConf = ''
      FRIENDLYNAME "Virtual PCD"
      DEVICENAME   /dev/null:0x8C7B
      LIBPATH      /nix/store/fake-vpcd/lib/libifdvpcd.so
      CHANNELID    0x8C7B
    '';
  };

  cfgA = scenarioA.config;
  cfgB = scenarioB.config;
  cfgC = scenarioC.config;
  cfgD = scenarioD.config;
  cfgE = scenarioE.config;
  cfgF = scenarioF.config;
in
{
  # --------------------------------------------------------------------------
  # 1. pcscd socket — wantedBy, DefaultDependencies, Before ordering
  # --------------------------------------------------------------------------
  pcscd-socket = assertEval "pcscd-socket" [
    (lib.assertMsg
      (cfgA.boot.initrd.systemd.sockets ? pcscd)
      "pcscd socket must be defined when module is enabled"
    )
    (lib.assertMsg
      (builtins.elem "cryptsetup-pre.target" cfgA.boot.initrd.systemd.sockets.pcscd.wantedBy)
      "pcscd socket must be wantedBy cryptsetup-pre.target"
    )
    (lib.assertMsg
      (cfgA.boot.initrd.systemd.sockets.pcscd.unitConfig.DefaultDependencies == false)
      "pcscd socket must have DefaultDependencies=false"
    )
    (lib.assertMsg
      (cfgA.boot.initrd.systemd.sockets.pcscd.listenStreams == [ "/run/pcscd/pcscd.comm" ])
      "pcscd socket must listen on /run/pcscd/pcscd.comm"
    )
  ];

  # --------------------------------------------------------------------------
  # 2. pcscd service — ordering, flags, environment
  # --------------------------------------------------------------------------
  pcscd-service = assertEval "pcscd-service" [
    (lib.assertMsg
      (cfgA.boot.initrd.systemd.services ? pcscd)
      "pcscd service must be defined when module is enabled"
    )
    (lib.assertMsg
      (builtins.elem "pcscd.socket" cfgA.boot.initrd.systemd.services.pcscd.after)
      "pcscd service must be after pcscd.socket"
    )
    (lib.assertMsg
      (builtins.elem "cryptsetup-pre.target" cfgA.boot.initrd.systemd.services.pcscd.wantedBy)
      "pcscd service must be wantedBy cryptsetup-pre.target (eager start)"
    )
    (lib.assertMsg
      (builtins.elem "cryptsetup-pre.target" cfgA.boot.initrd.systemd.services.pcscd.before)
      "pcscd service must be before cryptsetup-pre.target"
    )
    (lib.assertMsg
      (cfgA.boot.initrd.systemd.services.pcscd.unitConfig.DefaultDependencies == false)
      "pcscd service must have DefaultDependencies=false"
    )
    (lib.assertMsg
      (lib.hasInfix "-f -x -c" cfgA.boot.initrd.systemd.services.pcscd.serviceConfig.ExecStart)
      "pcscd ExecStart must include -f -x -c flags"
    )
    (lib.assertMsg
      (lib.hasInfix "pcscd" cfgA.boot.initrd.systemd.services.pcscd.serviceConfig.ExecStart)
      "pcscd ExecStart must invoke pcscd binary"
    )
    (lib.assertMsg
      (cfgA.boot.initrd.systemd.services.pcscd.environment ? PCSCLITE_HP_DROPDIR)
      "pcscd service must set PCSCLITE_HP_DROPDIR environment variable"
    )
  ];

  # --------------------------------------------------------------------------
  # 3. Store paths — cryptsetup plugin, default PKCS#11 module, pcscd
  # --------------------------------------------------------------------------
  store-paths =
    let
      sources = storePathSources cfgA;
    in
    assertEval "store-paths" [
      (lib.assertMsg
        (builtins.any
          (p: lib.hasInfix "libcryptsetup-token-systemd-pkcs11.so" p)
          sources
        )
        "storePaths must include libcryptsetup-token-systemd-pkcs11.so"
      )
      (lib.assertMsg
        (builtins.any
          (p: lib.hasInfix "libykcs11.so" p)
          sources
        )
        "storePaths must include libykcs11.so (default PKCS#11 module)"
      )
      (lib.assertMsg
        (builtins.any
          (p: lib.hasInfix "pcscd" p)
          sources
        )
        "storePaths must include pcscd binary"
      )
    ];

  # --------------------------------------------------------------------------
  # 4. p11-kit module config in initrd contents (default: ykcs11)
  # --------------------------------------------------------------------------
  p11-kit-module = assertEval "p11-kit-module" [
    (lib.assertMsg
      (cfgA.boot.initrd.systemd.contents ? "/etc/pkcs11/modules/ykcs11.module")
      "initrd contents must include p11-kit module file for default module name"
    )
    (lib.assertMsg
      (lib.hasInfix "libykcs11.so"
        cfgA.boot.initrd.systemd.contents."/etc/pkcs11/modules/ykcs11.module".text
      )
      "p11-kit module file must reference libykcs11.so"
    )
  ];

  # --------------------------------------------------------------------------
  # 5. reader.conf.d directory in initrd contents (pcsclite 2.x directory scan)
  # --------------------------------------------------------------------------
  reader-conf = assertEval "reader-conf" [
    (lib.assertMsg
      (cfgA.boot.initrd.systemd.contents ? "/etc/reader.conf.d")
      "initrd contents must include /etc/reader.conf.d (pcsclite 2.x directory)"
    )
  ];

  # --------------------------------------------------------------------------
  # 6. Kernel modules — USB HID/host controllers force-loaded, no "ccid"
  # --------------------------------------------------------------------------
  kernel-modules = assertEval "kernel-modules" [
    (lib.assertMsg
      (builtins.elem "usbhid" cfgA.boot.initrd.kernelModules)
      "kernelModules must include usbhid"
    )
    (lib.assertMsg
      (builtins.elem "xhci_pci" cfgA.boot.initrd.kernelModules)
      "kernelModules must include xhci_pci"
    )
    (lib.assertMsg
      (!(builtins.elem "ccid" cfgA.boot.initrd.kernelModules))
      "kernelModules must NOT include ccid (it's a userspace driver, not a kernel module)"
    )
    (lib.assertMsg
      (!(builtins.elem "ccid" cfgA.boot.initrd.availableKernelModules))
      "availableKernelModules must NOT include ccid (it's a userspace driver, not a kernel module)"
    )
  ];

  # --------------------------------------------------------------------------
  # 7. Module disabled — nothing should be added
  # --------------------------------------------------------------------------
  disabled =
    let
      sourcesB = storePathSources cfgB;
    in
    assertEval "disabled" [
      (lib.assertMsg
        (!(cfgB.boot.initrd.systemd.sockets ? pcscd))
        "pcscd socket must NOT exist when module is disabled"
      )
      (lib.assertMsg
        (!(cfgB.boot.initrd.systemd.services ? pcscd))
        "pcscd service must NOT exist when module is disabled"
      )
      (lib.assertMsg
        (!(builtins.any
          (p: lib.hasInfix "libcryptsetup-token-systemd-pkcs11.so" p)
          sourcesB
        ))
        "storePaths must NOT include pkcs11 plugin when module is disabled"
      )
    ];

  # --------------------------------------------------------------------------
  # 8. Multiple PKCS#11 modules (Scenario C: ykcs11 + opensc)
  # --------------------------------------------------------------------------
  multi-module =
    let
      sourcesC = storePathSources cfgC;
    in
    assertEval "multi-module" [
      # Both p11-kit module files exist
      (lib.assertMsg
        (cfgC.boot.initrd.systemd.contents ? "/etc/pkcs11/modules/ykcs11.module")
        "ykcs11 p11-kit module file must exist"
      )
      (lib.assertMsg
        (cfgC.boot.initrd.systemd.contents ? "/etc/pkcs11/modules/opensc.module")
        "opensc p11-kit module file must exist"
      )
      # Both module files reference correct .so
      (lib.assertMsg
        (lib.hasInfix "libykcs11.so"
          cfgC.boot.initrd.systemd.contents."/etc/pkcs11/modules/ykcs11.module".text
        )
        "ykcs11 module file must reference libykcs11.so"
      )
      (lib.assertMsg
        (lib.hasInfix "opensc-pkcs11.so"
          cfgC.boot.initrd.systemd.contents."/etc/pkcs11/modules/opensc.module".text
        )
        "opensc module file must reference opensc-pkcs11.so"
      )
      # Both .so files in storePaths
      (lib.assertMsg
        (builtins.any (p: lib.hasInfix "libykcs11.so" p) sourcesC)
        "storePaths must include libykcs11.so"
      )
      (lib.assertMsg
        (builtins.any (p: lib.hasInfix "opensc-pkcs11.so" p) sourcesC)
        "storePaths must include opensc-pkcs11.so"
      )
    ];

  # --------------------------------------------------------------------------
  # 9. Warning fires when LUKS device is present but pkcs11-uri= is missing
  # --------------------------------------------------------------------------
  missing-pkcs11-uri = assertEval "missing-pkcs11-uri" [
    (lib.assertMsg
      (builtins.any (w: lib.hasInfix "pkcs11-uri" w) cfgD.warnings)
      "a NixOS warning must fire when LUKS devices exist but none have pkcs11-uri= in crypttabExtraOpts"
    )
  ];

  # --------------------------------------------------------------------------
  # 10. No warning when at least one LUKS device has pkcs11-uri= set
  # --------------------------------------------------------------------------
  pkcs11-uri-present = assertEval "pkcs11-uri-present" [
    (lib.assertMsg
      (!(builtins.any (w: lib.hasInfix "pkcs11-uri" w) cfgE.warnings))
      "no warning must fire when a LUKS device has pkcs11-uri= in crypttabExtraOpts"
    )
  ];

  # --------------------------------------------------------------------------
  # 11. pcscd.readerConf — content flows into /etc/reader.conf.d in initrd
  #     (pcsclite 2.x requires a directory, not a single file)
  # --------------------------------------------------------------------------
  pcscd-reader-conf = assertEval "pcscd-reader-conf" [
    (lib.assertMsg
      (cfgA.boot.initrd.systemd.pkcs11.pcscd.readerConf == "")
      "pcscd.readerConf must default to empty string"
    )
    # /etc/reader.conf.d must exist in initrd contents regardless of readerConf value
    (lib.assertMsg
      (cfgA.boot.initrd.systemd.contents ? "/etc/reader.conf.d")
      "/etc/reader.conf.d must be present in initrd contents (default scenario)"
    )
    (lib.assertMsg
      (cfgF.boot.initrd.systemd.contents ? "/etc/reader.conf.d")
      "/etc/reader.conf.d must be present in initrd contents (vpcd scenario)"
    )
    # The option value itself must round-trip correctly
    (lib.assertMsg
      (lib.hasInfix "Virtual PCD" cfgF.boot.initrd.systemd.pkcs11.pcscd.readerConf)
      "pcscd.readerConf must retain FRIENDLYNAME content"
    )
    (lib.assertMsg
      (lib.hasInfix "libifdvpcd.so" cfgF.boot.initrd.systemd.pkcs11.pcscd.readerConf)
      "pcscd.readerConf must retain LIBPATH content"
    )
    # The reader.conf.d directory is built via pkgs.runCommand (source derivation).
    (lib.assertMsg
      (cfgF.boot.initrd.systemd.contents."/etc/reader.conf.d" ? source)
      "/etc/reader.conf.d in initrd contents must use .source (runCommand derivation)"
    )
  ];
}

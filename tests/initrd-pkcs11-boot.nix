# Full boot-cycle VM integration test for the initrd-pkcs11 NixOS module.
#
# Tests the real LUKS unlock flow: enroll a softhsm PKCS#11 token on first
# boot, then reboot into a specialisation where systemd-cryptsetup unlocks
# the LUKS volume automatically during initrd — the same path a real YubiKey
# would take.
#
# REQUIRES: a host with KVM support.  Without KVM, QEMU falls back to TCG
# and the UEFI disk image builder + RSA crypto are prohibitively slow.
#
# See also: tests/initrd-pkcs11.nix for a lighter single-boot test that
# works (slowly) without KVM.
#
# Architecture note: the outer `pkgs` is the *host* platform (e.g.
# aarch64-darwin on macOS).  Inside `nodes.machine`, `pkgs` is the *VM*
# platform (aarch64-linux).  Store paths that must exist inside the VM
# (shared libraries, config files) MUST use the node's `pkgs`, not the
# host's.  The `testTokenData` derivation is an exception — it runs at
# Nix build time on the host, but its output is arch-independent data
# files (serialised softhsm token state), so they work in any VM.

# https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/tests/systemd-initrd-luks-tpm2.nix
# https://github.com/NixOS/nixpkgs/commit/b13891782fdec1b72e1e9ab4f86fce1638f20203

{ pkgs, self, ... }:
let
  tokenDir = "/var/lib/softhsm/tokens";

  # Pre-create softhsm token with an RSA key pair and self-signed X.509
  # certificate at Nix build time.  systemd-cryptenroll requires a
  # CKO_CERTIFICATE object on the token.
  #
  # This runs on the *host* platform.  The output is arch-independent
  # data files (softhsm token directory), safe to copy into a Linux VM.
  testTokenData = pkgs.runCommand "softhsm-test-token" {
    nativeBuildInputs = with pkgs; [
      softhsm
      opensc # pkcs11-tool
      openssl
    ];
  } ''
    mkdir -p $out

    export SOFTHSM2_CONF=$TMPDIR/softhsm2.conf
    cat > $SOFTHSM2_CONF <<EOF
    directories.tokendir = $out
    objectstore.backend = file
    EOF

    # Generate RSA 2048 key pair + self-signed certificate
    openssl genrsa -out $TMPDIR/key.pem 2048 2>/dev/null
    openssl req -new -x509 -key $TMPDIR/key.pem -out $TMPDIR/cert.pem \
      -days 365 -subj "/CN=test-luks-pkcs11" 2>/dev/null
    openssl x509 -in $TMPDIR/cert.pem -outform DER -out $TMPDIR/cert.der

    # Initialise softhsm token (PIN=1234, SO-PIN=12345678)
    softhsm2-util --init-token --free \
      --label test --so-pin 12345678 --pin 1234

    # Import private key into the token
    softhsm2-util --import $TMPDIR/key.pem \
      --token test --pin 1234 --label luks-key --id 01

    # Import the matching certificate (needed by systemd-cryptenroll).
    # Uses the *host* softhsm .so — this is a build-time operation.
    pkcs11-tool --module ${pkgs.softhsm}/lib/softhsm/libsofthsm2.so \
      --token-label test --login --pin 1234 \
      --write-object $TMPDIR/cert.der --type cert --label luks-key --id 01
  '';

  pkcs11Uri = "pkcs11:token=test";
in
pkgs.testers.runNixOSTest {
  name = "initrd-pkcs11-boot";

  nodes.machine =
    { config, pkgs, lib, ... }:
    let
      # VM-platform (Linux) softhsm .so — used for p11-kit config,
      # module registration, and initrd contents.
      softhsmModule = "${pkgs.softhsm}/lib/softhsm/libsofthsm2.so";

      softhsmConf = pkgs.writeText "softhsm2.conf" ''
        directories.tokendir = ${tokenDir}
        objectstore.backend = file
      '';

      # Script to copy read-only token data from the initrd to a
      # writable tmpfs location.  Uses /bin/ paths provided by extraBin.
      copySofthsmTokens = pkgs.writeShellScript "copy-softhsm-tokens" ''
        /bin/mkdir -p ${tokenDir}
        /bin/cp -a /var/lib/softhsm/tokens-ro/* ${tokenDir}/
        /bin/chmod -R u+w ${tokenDir}
      '';
    in
    {
      virtualisation = {
        emptyDiskImages = [ 512 ];
        useBootLoader = true;
        mountHostNixStore = true;
        efi.OVMF = pkgs.OVMFFull; # this really should be the default. Only OVMFFull contains TCG - as seen in https://github.com/NixOS/nixpkgs/commit/4dd4e54e2ce4a669d1bc139ae2783f24fa18c580
        useEFIBoot = true;
      };
      boot.loader.systemd-boot.enable = true;
      boot.initrd.systemd.enable = true;

      environment.systemPackages = with pkgs; [ cryptsetup ];

      # Running system: softhsm config + p11-kit module registration
      environment.etc."softhsm2.conf".source = softhsmConf;
      environment.etc."pkcs11/modules/softhsm.module".text = ''
        module: ${softhsmModule}
      '';

      specialisation.boot-luks.configuration = {
        imports = [ self.nixosModules.initrd-pkcs11 ];

        boot.initrd.systemd.pkcs11 = {
          enable = true;
          modules = {
            softhsm = softhsmModule;
          };
        };

        boot.initrd.luks.devices = lib.mkVMOverride {
          cryptroot = {
            device = "/dev/vdb";
            crypttabExtraOpts = [
              "pkcs11-uri=auto"
              "token-timeout=10"
            ];
          };
        };
        virtualisation.rootDevice = "/dev/mapper/cryptroot";

        # --- Softhsm-specific initrd additions ---
        # (These would NOT be needed for a real YubiKey — they're only
        # needed because softhsm requires filesystem-based token data
        # and a config file, while a YubiKey carries its keys in hardware.)

        # Softhsm config + pre-built token data in initrd.
        # Token data is stored at a read-only path; a oneshot service
        # copies it to a writable location before cryptsetup runs
        # (softhsm needs write access for internal lock files).
        boot.initrd.systemd.contents = {
          "/etc/softhsm2.conf".source = softhsmConf;
          "/var/lib/softhsm/tokens-ro".source = testTokenData;
        };

        # The copy script + coreutils must be explicitly in storePaths
        # because make-initrd-ng does not follow Nix store references
        # in shell scripts.
        boot.initrd.systemd.storePaths = [ copySofthsmTokens ];

        boot.initrd.systemd.extraBin = {
          mkdir = "${pkgs.coreutils}/bin/mkdir";
          cp = "${pkgs.coreutils}/bin/cp";
          chmod = "${pkgs.coreutils}/bin/chmod";
        };

        # Copy read-only token data to a writable location before
        # cryptsetup runs.  Following the clevis pattern: wantedBy the
        # specific cryptsetup service, ordered Before it, and
        # DefaultDependencies=no to avoid the sysinit.target deadlock.
        boot.initrd.systemd.services.softhsm-copy-tokens = {
          description = "Copy softhsm tokens to writable tmpfs";
          wantedBy = [ "systemd-cryptsetup@cryptroot.service" ];
          before = [
            "systemd-cryptsetup@cryptroot.service"
            "cryptsetup-pre.target"
          ];
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${copySofthsmTokens}";
          };
        };

        # Set SOFTHSM2_CONF + PIN for all initrd services including
        # generator-spawned systemd-cryptsetup@.
        # PIN is required because systemd's pkcs11_token_login() reads
        # the token PIN from $PIN env var, not from the URI.
        # (Not needed for pcscd-based tokens like YubiKey with interactive PIN.)
        boot.initrd.systemd.settings.Manager.DefaultEnvironment =
          lib.mkForce "PATH=/bin:/sbin SOFTHSM2_CONF=/etc/softhsm2.conf PIN=1234";

      };
    };

  testScript = ''
    # --- First boot: create LUKS volume and enroll softhsm PKCS#11 token ---
    machine.wait_for_unit("multi-user.target")

    # Copy pre-built token data to writable location
    machine.succeed("mkdir -p ${tokenDir}")
    machine.succeed("cp -r ${testTokenData}/* ${tokenDir}/")

    # Create LUKS2 volume with a temporary passphrase
    machine.succeed("echo -n supersecret | cryptsetup luksFormat -q --iter-time=1 /dev/vdb -")
    machine.succeed("echo -n supersecret | cryptsetup luksOpen -q /dev/vdb cryptroot")
    machine.succeed("mkfs.ext4 /dev/mapper/cryptroot")

    # Enroll the softhsm PKCS#11 token.
    # PIN= is required because systemd's pkcs11_token_login() reads the
    # PKCS#11 token PIN from $PIN env var, NOT from the pin-value= attribute
    # in the PKCS#11 URI.
    machine.succeed(
      "SOFTHSM2_CONF=/etc/softhsm2.conf "
      "PASSWORD=supersecret "
      "PIN=1234 "
      "SYSTEMD_LOG_LEVEL=debug "
      "systemd-cryptenroll "
      "--pkcs11-token-uri='${pkcs11Uri}' "
      "/dev/vdb "
      "|& systemd-cat"
    )

    # Verify enrollment succeeded
    machine.succeed("cryptsetup luksDump /dev/vdb | grep -q pkcs11")

    # --- Reboot into specialisation that unlocks via PKCS#11 ---
    machine.succeed("bootctl set-default nixos-generation-1-specialisation-boot-luks.conf")
    machine.succeed("sync")
    machine.crash()

    # --- Second boot: verify LUKS unlocked via softhsm PKCS#11 ---
    # If the PKCS#11 token isn't found, systemd-cryptsetup falls back to
    # a passphrase prompt that hangs forever — the 120s timeout catches this.
    machine.wait_for_unit("multi-user.target", timeout=120)
    assert "/dev/mapper/cryptroot on / type ext4" in machine.succeed("mount")
  '';
}

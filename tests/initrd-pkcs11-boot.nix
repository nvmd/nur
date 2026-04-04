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

# https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/tests/systemd-initrd-luks-tpm2.nix
# https://github.com/NixOS/nixpkgs/commit/b13891782fdec1b72e1e9ab4f86fce1638f20203

{ pkgs, self }:
let
  lib = pkgs.lib;
  softhsmModule = "${pkgs.softhsm}/lib/softhsm/libsofthsm2.so";

  tokenDir = "/var/lib/softhsm/tokens";

  softhsmConf = pkgs.writeText "softhsm2.conf" ''
    directories.tokendir = ${tokenDir}
    objectstore.backend = file
  '';

  # Pre-create softhsm token with an RSA key pair and self-signed X.509
  # certificate at Nix build time.  systemd-cryptenroll requires a
  # CKO_CERTIFICATE object on the token.
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

    # Import the matching certificate (needed by systemd-cryptenroll)
    pkcs11-tool --module ${softhsmModule} \
      --token-label test --login --pin 1234 \
      --write-object $TMPDIR/cert.der --type cert --label luks-key --id 01
  '';

  # PKCS#11 URI with embedded PIN for non-interactive operation.
  pkcs11Uri = "pkcs11:token=test;pin-value=1234";
in
pkgs.testers.runNixOSTest {
  name = "initrd-pkcs11-boot";

  nodes.machine =
    { config, pkgs, ... }:
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
              "token-timeout=60"
            ];
          };
        };
        virtualisation.rootDevice = "/dev/mapper/cryptroot";

        # --- Softhsm-specific initrd additions ---
        # (These would NOT be needed for a real YubiKey — they're only
        # needed because softhsm requires filesystem-based token data
        # and a config file, while a YubiKey carries its keys in hardware.)

        # Softhsm config + pre-built token data in initrd
        boot.initrd.systemd.contents = {
          "/etc/softhsm2.conf".source = softhsmConf;
          "${tokenDir}".source = testTokenData;
        };

        # Set SOFTHSM2_CONF for all initrd services including
        # generator-spawned systemd-cryptsetup@.
        # (Not needed for pcscd-based tokens like YubiKey.)
        boot.initrd.systemd.settings.Manager.DefaultEnvironment =
          lib.mkForce "PATH=/bin:/sbin SOFTHSM2_CONF=/etc/softhsm2.conf";

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

    # Enroll the softhsm PKCS#11 token
    machine.succeed(
      "SOFTHSM2_CONF=/etc/softhsm2.conf "
      "PASSWORD=supersecret "
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
    machine.wait_for_unit("multi-user.target")
    assert "/dev/mapper/cryptroot on / type ext4" in machine.succeed("mount")
  '';
}

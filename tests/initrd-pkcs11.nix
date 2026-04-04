# VM integration test for the initrd-pkcs11 NixOS module.
#
# Uses softhsm as a software PKCS#11 token to test the p11-kit → PKCS#11
# module → libcryptsetup-token-systemd-pkcs11.so chain.
#
# NOTE: This does NOT test the pcscd/CCID/USB stack (softhsm is a pure
# software token that doesn't need pcscd).  Testing the full pcscd chain
# would require a virtual smartcard (e.g. vsmartcard-vpcd) or real hardware.
#
# This test does NOT use useBootLoader/specialisation/reboot (which requires
# a UEFI disk image builder that is very slow without KVM).  Instead it
# tests enrollment + unlock within a single boot using systemd-cryptsetup
# directly.
#
# Architecture note: the outer `pkgs` is the *host* platform (e.g.
# aarch64-darwin on macOS).  Inside `nodes.machine`, `pkgs` is the *VM*
# platform (aarch64-linux).  Store paths that must exist inside the VM
# (shared libraries, config files) MUST use the node's `pkgs`, not the
# host's.  The `testTokenData` derivation is an exception — it runs at
# Nix build time on the host, but its output is arch-independent data
# files (serialised softhsm token state), so they work in any VM.
{ pkgs, self }:
let
  tokenDir = "/var/lib/softhsm/tokens";

  # Pre-create softhsm token with an RSA 2048 key pair and self-signed
  # X.509 certificate at Nix build time.  systemd-cryptenroll requires a
  # CKO_CERTIFICATE object on the token.
  #
  # RSA is used because: (a) it matches real YubiKey PIV key types, and
  # (b) softhsm2-util sets the correct CKA_DECRYPT usage flag on RSA
  # private keys, which systemd needs for PKCS#11 LUKS unlock.  EC keys
  # would need CKA_DERIVE for ECDH, which softhsm2-util doesn't set.
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

    # Import RSA private key into the token
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
  name = "initrd-pkcs11-softhsm";

  nodes.machine =
    { config, pkgs, ... }:
    let
      # VM-platform (Linux) softhsm .so — used for p11-kit config,
      # module registration, and test-time pkcs11-tool invocations.
      softhsmModule = "${pkgs.softhsm}/lib/softhsm/libsofthsm2.so";

      softhsmConf = pkgs.writeText "softhsm2.conf" ''
        directories.tokendir = ${tokenDir}
        objectstore.backend = file
      '';
    in
    {
      imports = [ self.nixosModules.initrd-pkcs11 ];

      virtualisation.emptyDiskImages = [ 512 ];

      boot.initrd.systemd.enable = true;

      # Enable the module (for store paths / p11-kit config in initrd)
      boot.initrd.systemd.pkcs11 = {
        enable = true;
        modules = {
          softhsm = softhsmModule;
        };
      };

      environment.systemPackages = with pkgs; [
        cryptsetup
        softhsm
        opensc
        p11-kit
      ];

      # softhsm config + p11-kit module registration on running system
      environment.etc."softhsm2.conf".source = softhsmConf;
      environment.etc."pkcs11/modules/softhsm.module".text = ''
        module: ${softhsmModule}
      '';
    };

  # testScript is a function so we can access the node's evaluated config
  # and derive VM-platform (Linux) store paths for use in test commands.
  testScript = { nodes, ... }:
    let
      # Read back the Linux softhsm .so path from the node's evaluated config
      softhsmModule = nodes.machine.boot.initrd.systemd.pkcs11.modules.softhsm;
    in
    ''
      machine.wait_for_unit("multi-user.target")

      # --- Set up softhsm token data ---
      machine.succeed("mkdir -p ${tokenDir}")
      machine.succeed("cp -r ${testTokenData}/* ${tokenDir}/")
      machine.succeed("export SOFTHSM2_CONF=/etc/softhsm2.conf && softhsm2-util --show-slots | grep -q 'test'")

      # --- Verify p11-kit sees softhsm and token objects are accessible ---
      machine.succeed("SOFTHSM2_CONF=/etc/softhsm2.conf p11-kit list-modules | grep -q softhsm")
      machine.succeed(
        "SOFTHSM2_CONF=/etc/softhsm2.conf pkcs11-tool"
        " --module ${softhsmModule} --token-label test"
        " --login --pin 1234 --list-objects | grep -q luks-key"
      )

      # --- Create LUKS2 volume ---
      machine.succeed(
        "echo -n supersecret | cryptsetup luksFormat -q --iter-time=1 --pbkdf=pbkdf2 /dev/vdb -"
      )

      # --- Enroll softhsm PKCS#11 token ---
      # PIN= is required because systemd's pkcs11_token_login() reads the
      # PKCS#11 token PIN from $PIN env var, NOT from the pin-value= attribute
      # in the PKCS#11 URI.  Without $PIN, it falls back to ask_password_auto()
      # with infinite timeout and hangs.
      machine.succeed(
        "SOFTHSM2_CONF=/etc/softhsm2.conf "
        "PASSWORD=supersecret "
        "PIN=1234 "
        "systemd-cryptenroll "
        "--pkcs11-token-uri='${pkcs11Uri}' "
        "/dev/vdb"
      )

      # --- Verify enrollment ---
      machine.succeed("cryptsetup luksDump /dev/vdb | grep -q systemd-pkcs11")

      # --- Test unlock via systemd-cryptsetup ---
      machine.succeed(
        "SOFTHSM2_CONF=/etc/softhsm2.conf "
        "PIN=1234 "
        "systemd-cryptsetup attach test-crypt /dev/vdb - 'pkcs11-uri=${pkcs11Uri}'"
      )

      # --- Verify the volume is open ---
      machine.succeed("test -b /dev/mapper/test-crypt")

      # --- Create filesystem and verify mount ---
      machine.succeed("mkfs.ext4 -q /dev/mapper/test-crypt")
      machine.succeed("mkdir -p /mnt/test && mount /dev/mapper/test-crypt /mnt/test")
      machine.succeed("echo 'pkcs11-test-ok' > /mnt/test/marker")
      machine.succeed("grep -q 'pkcs11-test-ok' /mnt/test/marker")

      # --- Clean up ---
      machine.succeed("umount /mnt/test")
      machine.succeed("rmdir /mnt/test")
      machine.succeed("cryptsetup close test-crypt")


      ## close the luks volume and reopen, checking marker file content

      # --- Test unlock via systemd-cryptsetup ---
      machine.succeed(
        "SOFTHSM2_CONF=/etc/softhsm2.conf "
        "PIN=1234 "
        "systemd-cryptsetup attach test-crypt /dev/vdb - 'pkcs11-uri=${pkcs11Uri}'"
      )

      # --- Verify the volume is open ---
      machine.succeed("test -b /dev/mapper/test-crypt")
      machine.succeed("mkdir -p /mnt/test && mount /dev/mapper/test-crypt /mnt/test")
      machine.succeed("grep -q 'pkcs11-test-ok' /mnt/test/marker")

      # --- Clean up ---
      machine.succeed("umount /mnt/test")
      machine.succeed("rmdir /mnt/test")
      machine.succeed("cryptsetup close test-crypt")
    '';
}

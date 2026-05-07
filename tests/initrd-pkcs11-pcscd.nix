# pcscd infrastructure smoke test for the initrd-pkcs11 NixOS module.
#
# Tests the pcscd/CCID stack that the softhsm-based tests bypass entirely.
# Uses vsmartcard-vpcd to configure a virtual serial reader in reader.conf.
# pcscd loads libifdvpcd.so and creates "Virtual PCD 00 00" immediately on
# startup, even without a vicc card server connected.
#
# What this tests:
#   - pcscd starts eagerly in the initrd (wantedBy cryptsetup-pre.target)
#   - pcscd reads reader.conf and finds the LIBPATH for libifdvpcd.so
#   - pcscd loads libifdvpcd.so from the initrd store path
#   - pcscd logs the "Virtual PCD" reader (visible in post-boot journal)
#
# What this does NOT test:
#   - Actual card APDU responses (no vicc server, no virtual card)
#   - PKCS#11 key operations via pcscd  ← Stage 2 (see pcscd-testing-plan.md)
#   - LUKS unlock via pcscd path  ← covered by initrd-pkcs11-boot.nix (softhsm)
#
# Single-boot only — no UEFI or disk image builder needed.  Works under TCG.
#
# Architecture note: pkgs inside nodes.machine is aarch64-linux.
# pkgs.vsmartcard-vpcd is broken = isDarwin, so it builds fine for Linux.

{ pkgs, self, ... }:
let
  # vpcd TCP port (decimal 35963 = hex 0x8C4B).
  # In listening mode (DEVICENAME = /dev/null:<port>), vpcd waits for an
  # incoming vicc connection but creates the "Virtual PCD" reader immediately.
  vpcdPort = 35963;
  vpcdPortHex = "0x8C4B";
in
pkgs.testers.runNixOSTest {
  name = "initrd-pkcs11-pcscd";

  nodes.machine =
    { config, pkgs, lib, ... }:
    let
      # vpcd serial driver library.  This is NOT a hotplug driver — it is
      # configured via reader.conf (LIBPATH stanza), not PCSCLITE_HP_DROPDIR.
      vpcdLib = "${pkgs.vsmartcard-vpcd}/var/lib/pcsc/drivers/serial/libifdvpcd.so";
    in
    {
      imports = [ self.nixosModules.initrd-pkcs11 ];

      virtualisation.emptyDiskImages = [ 512 ];

      boot.initrd.systemd.enable = true;

      boot.initrd.systemd.pkcs11 = {
        enable = true;

        # Configure the vpcd virtual reader in reader.conf.
        # Listening mode (/dev/null) means vpcd waits for a vicc client but
        # creates the "Virtual PCD 00 00" reader right away on driver load.
        pcscd.readerConf = ''
          FRIENDLYNAME "Virtual PCD"
          DEVICENAME   /dev/null:${vpcdPortHex}
          LIBPATH      ${vpcdLib}
          CHANNELID    ${vpcdPortHex}
        '';
      };

      # libifdvpcd.so is a serial reader driver (not a hotplug plugin).
      # It must be in storePaths explicitly because make-initrd-ng does not
      # follow Nix store references inside text files (reader.conf).
      boot.initrd.systemd.storePaths = [ vpcdLib ];

      # The smoke test has no LUKS device, so cryptsetup-pre.target is never
      # activated in the initrd.  Without it, pcscd's wantedBy=cryptsetup-pre.target
      # never fires.  Pull pcscd into initrd.target so it still starts and
      # exercises the reader-detection path.
      #
      # In a real deployment, LUKS devices with pkcs11-uri=auto trigger
      # cryptsetup-pre.target automatically — this override is test-only.
      boot.initrd.systemd.services.pcscd.wantedBy = [ "initrd.target" ];
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # systemd forwards initrd journal entries to the main boot journal during
    # switch-root, so journalctl --boot=0 captures pcscd output from initrd.

    # Verify pcscd loaded the vpcd driver and created the virtual reader.
    # pcscd logs "Adding reader: Virtual PCD 00 00" when libifdvpcd.so
    # registers the reader, before any vicc card server connects.
    machine.succeed(
      "journalctl --boot=0 --output=cat | grep -i 'Virtual PCD'"
    )

    # Verify pcscd service did not exit with a failure.
    # (It exits cleanly via --auto-exit after the initrd transitions.)
    machine.succeed(
      "journalctl --boot=0 -u pcscd.service --output=cat"
      " | grep -qiv 'failed to load\\|Segmentation\\|SIGABRT'"
    )
  '';
}

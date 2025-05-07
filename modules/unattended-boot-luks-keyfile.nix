{ config, lib, pkgs, ... }:

let
  cfg = config.boot.initrd.unattended-boot-luks-keyfile;
in {

  options.boot.initrd.unattended-boot-luks-keyfile = {

    enable = lib.mkEnableOption "unattended-boot-luks-keyfile";

    unlockDisk1 = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "unattendedBootDisk1";
    };

    unlockDisk2 = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "unattendedBootDisk2";
    };

  };

  config = lib.mkIf cfg.enable {
    # this didn't work for me
    # https://nixos.wiki/wiki/Full_Disk_Encryption#Option_2:_Copy_Key_as_file_onto_a_vfat_usb_stick
    # this, with `preOpenCommands` works
    # https://github.com/nix-community/disko/issues/289

    # Kernel modules needed for mounting USB VFAT devices in initrd stage
    boot.initrd.kernelModules = [
      "uas" "usbcore" "usb_storage"
      "vfat" "nls_cp437" "nls_iso8859_1"
      "ext4"  # in case ext4 is not configured as builtin
    ];

    boot.initrd.luks.devices = let
      deviceName = "cryptroot";
      machineId = config.networking.hostName;
      unlockDiskMountPoint = "/key";
      mountUnlockDisk = disk: "mount -n -t ${disk.fs} -o ro `findfs ${disk.tag}=${disk.value}` ${unlockDiskMountPoint}";
    in {
      "${deviceName}" = {  # DISKO UNATTENDED BOOT
        keyFile = "${unlockDiskMountPoint}/${machineId}-${deviceName}.keyfile";
        # both /dev/disk/by-uuid/${unlockUuid1} and findfs UUID=${unlockUuid1} work
        preOpenCommands = ''
          mkdir -m 0700 -p ${unlockDiskMountPoint}
          sleep 2 # To make sure the usb key has been loaded
          ${mountUnlockDisk cfg.unlockDisk1} || ${mountUnlockDisk cfg.unlockDisk2}
        '';
        postOpenCommands = ''
          umount ${unlockDiskMountPoint}
        '';
        fallbackToPassword = true;
      };
    };

    services.udev.extraRules = let
      mkExcludeUnattendedBootDisk = disk: let
        envTag = {
          "UUID" = "ENV{ID_FS_UUID}";
          "PARTLABEL" = "ENV{PARTNAME}";
        }.${disk.tag};
        value = disk.value;
      in ''
        SUBSYSTEM=="block", ${envTag}=="${value}", ENV{UDISKS_IGNORE}="1"
      '';
    in ''
      # udisks2
      # some inspiration on how to debug when partitions still get mounted:
      #  https://github.com/storaged-project/udisks/issues/788
      #  with `udevadm info /dev/sda1`, `udevadm monitor`, ...
      #  example – "official" ignore file
      #  https://github.com/storaged-project/udisks/blob/master/data/80-udisks2.rules
      #SUBSYSTEM=="block", ENV{ID_FS_UUID}=="XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXXX", ENV{UDISKS_IGNORE}="1"

      # ignore unattended boot luks keyfile partitions
      ${mkExcludeUnattendedBootDisk cfg.unlockDisk1}
      ${mkExcludeUnattendedBootDisk cfg.unlockDisk2}
    '';

  };

}

{ config, lib, pkgs, ... }:

let
  cfg = config.boot.initrd.unattended-boot-luks-keyfile;
in {

  options.boot.initrd.unattended-boot-luks-keyfile = {

    enable = lib.mkEnableOption "unattended-boot-luks-keyfile";

    unlockDisks = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "disks for unattended luks partition unlock";
    };

  };

  config = lib.mkIf cfg.enable (let
    mapUnlockDisksToStr = sep: f: lib.concatMapAttrsStringSep sep (name: value: f value) cfg.unlockDisks;
  in {
    # this didn't work for me
    # https://nixos.wiki/wiki/Full_Disk_Encryption#Option_2:_Copy_Key_as_file_onto_a_vfat_usb_stick
    # this, with `preOpenCommands` works
    # https://github.com/nix-community/disko/issues/289

    # explicitly add kernel modules needed for mounting:
    # * USB VFAT devices in initrd stage
    # * any other filesystems used in `unlockDisks`,
    # ... assuming its loadable module name matches fs type as used
    # ... in `mount -t <fs type>`
    # (i.e. don't exclusively rely on what's built-in into the kernel)
    boot.initrd.kernelModules = [
      "uas" "usbcore" "usb_storage"
      "vfat" "nls_cp437" "nls_iso8859_1"
    ] ++ lib.mapAttrsToList (name: value: value.fs) cfg.unlockDisks;

    boot.initrd.luks.devices = let
      deviceName = "cryptroot";
      machineId = config.networking.hostName;
      unlockDiskMountPoint = "/key";
      mountUnlockDisk = disk: "mount -n -t ${disk.fs} -o ro `findfs ${disk.tag}=${disk.value}` ${unlockDiskMountPoint}";
      mountAnyUnlockDisk = mapUnlockDisksToStr " || " mountUnlockDisk;
    in {
      "${deviceName}" = {  # DISKO UNATTENDED BOOT
        keyFile = "${unlockDiskMountPoint}/${machineId}-${deviceName}.keyfile";
        # both /dev/disk/by-uuid/${unlockUuid1} and findfs UUID=${unlockUuid1} work
        preOpenCommands = ''
          mkdir -m 0700 -p ${unlockDiskMountPoint}
          sleep 2 # To make sure the usb key has been loaded
          ${mountAnyUnlockDisk}
        '';
        postOpenCommands = ''
          umount ${unlockDiskMountPoint}
        '';
        fallbackToPassword = true;
      };
    };

    services.udev.extraRules = let
      ignoreAllUnlockDisks = mapUnlockDisksToStr "\n" ignoreUnlockDiskRule;
      ignoreUnlockDiskRule = disk: let
        envTag = {
          "UUID" = "ENV{ID_FS_UUID}";
          "PARTLABEL" = "ENV{PARTNAME}";
        }.${disk.tag};
        value = disk.value;
      in ''SUBSYSTEM=="block", ${envTag}=="${value}", ENV{UDISKS_IGNORE}="1"'';
      # udisks2
      # some inspiration on how to debug when partitions still get mounted:
      #  https://github.com/storaged-project/udisks/issues/788
      #  with `udevadm info /dev/sda1`, `udevadm monitor`, ...
      #  example – "official" ignore file
      #  https://github.com/storaged-project/udisks/blob/master/data/80-udisks2.rules
      #SUBSYSTEM=="block", ENV{ID_FS_UUID}=="XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXXX", ENV{UDISKS_IGNORE}="1"
    in ''
      # ignore luks keyfile partitions used for unattended boot
      ${ignoreAllUnlockDisks}
    '';

  });

}

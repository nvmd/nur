{ config, lib, pkgs, ... }:

let
  cfg = config.boot.initrd.unattended-boot-luks-keyfile;
in {

  options.boot.initrd.unattended-boot-luks-keyfile = {

    enable = lib.mkEnableOption "unattended-boot-luks-keyfile";

    luksDevices = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        freeformType = lib.types.attrsOf lib.types.attrs;
      });
      default = {};
      description = ''
        disks for unattended luks partition unlock for the corresponding luks
        device
      '';
    };

  };

  config = let
    unlockDiskMountPoint = "/key";
    mapUnlockDisksToStr = disks: sep: f: lib.concatMapStringsSep sep (value: f value) disks;
    unlockDisks = luksDevice: lib.attrValues luksDevice;
    allUnlockDisks = lib.concatLists (lib.map lib.attrValues (lib.attrValues cfg.luksDevices));
  in lib.mkMerge [
    (lib.mkIf cfg.enable {

      # explicitly add kernel modules needed for mounting:
      # * USB VFAT devices in initrd stage
      # * any other filesystems used in `unlockDisks`,
      # ... assuming its loadable module name matches fs type as used
      # ... in `mount -t <fs type>`
      # (i.e. don't exclusively rely on what's built-in into the kernel)
      boot.initrd.kernelModules = [
        "uas" "usbcore" "usb_storage"
        "vfat" "nls_cp437" "nls_iso8859_1"
      ] ++ lib.map (disk: disk.fs) allUnlockDisks;

      services.udev.extraRules = let
        ignoreAllUnlockDisks = mapUnlockDisksToStr allUnlockDisks "\n" ignoreUnlockDiskRule;
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

      boot.initrd.luks.devices = let
        configureLuksDevice = deviceName: unlockDisksAttrs: let
          machineId = config.networking.hostName;
        in {  # DISKO UNATTENDED BOOT
          keyFile = "${unlockDiskMountPoint}/${machineId}-${deviceName}.keyfile";
        };
      in lib.mapAttrs configureLuksDevice cfg.luksDevices;

    })

    (lib.mkIf (cfg.enable && !config.boot.initrd.systemd.enable) {
      # this didn't work for me
      # https://nixos.wiki/wiki/Full_Disk_Encryption#Option_2:_Copy_Key_as_file_onto_a_vfat_usb_stick
      # this, with `preOpenCommands` works
      # https://github.com/nix-community/disko/issues/289

      boot.initrd.luks.devices = let
        configureLuksDevice = deviceName: unlockDisksAttrs: let
          mountUnlockDisk = disk: "mount -n -t ${disk.fs} -o ro `findfs ${disk.tag}=${disk.value}` ${unlockDiskMountPoint}";
          mountAnyUnlockDisk = mapUnlockDisksToStr (unlockDisks unlockDisksAttrs) " || " mountUnlockDisk;
        in {  # DISKO UNATTENDED BOOT
          # both /dev/disk/by-uuid/${unlockUuid1} and findfs UUID=${unlockUuid1} work
          preOpenCommands = ''
            mkdir -m 0700 -p ${unlockDiskMountPoint}
            sleep 2 # To make sure the usb key has been loaded
            ${mountAnyUnlockDisk}
          '';
          postOpenCommands = ''
            umount ${unlockDiskMountPoint}
          '';
          fallbackToPassword = true; # causes "is implied by systemd stage 1." when `boot.initrd.systemd.enable`
        };
      in lib.mapAttrs configureLuksDevice cfg.luksDevices;
    })

    # usb keyfile unlock with systemd initrd
    # https://discourse.nixos.org/t/systemd-initrd-for-usb-based-luks-unlocking-root/59179/13
    # https://discourse.nixos.org/t/auto-unlock-root-on-luks-with-systemd-initrd/28329/2
    (lib.mkIf (cfg.enable && config.boot.initrd.systemd.enable) {
      warnings = [''
        EXPERIMENTAL FEATURE

        boot.initrd.unattended-boot-luks-keyfile is experimental and incomplete when
        boot.initrd.systemd.enable == true
      ''];

      boot.initrd.systemd.mounts = let
        disk = cfg.unlockDisks."0-default";
      in [
        {
          what = "${disk.tag}=${disk.value}";
          # what = "/dev/disk/by-label/KEYS";
          # what = "UUID=b501f1b9-7714-472c-988f-3c997f146a17";
          where = unlockDiskMountPoint;
          options = "ro";
          type = disk.fs;
        }
      ];

      # is this needed for the password fallback when usb key isn't present?
      boot.initrd.systemd.services."systemd-cryptsetup@${cfg.luksDeviceName}" = {
        overrideStrategy = "asDropin";
        unitConfig = {
          RequiresMountsFor = [ ];
          WantsMountsFor = [ unlockDiskMountPoint ];
        };
      };
    })
  ];

}

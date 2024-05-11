# this didn't work for me
# https://nixos.wiki/wiki/Full_Disk_Encryption#Option_2:_Copy_Key_as_file_onto_a_vfat_usb_stick
# this, with `preOpenCommands` works
# https://github.com/nix-community/disko/issues/289
{ unlockDisk1, unlockDisk2 }:
{ config, lib, pkgs, ... }:

{
  # Kernel modules needed for mounting USB VFAT devices in initrd stage
  boot.initrd.kernelModules = ["uas" "usbcore" "usb_storage" "vfat" "nls_cp437" "nls_iso8859_1"];

  boot.initrd.luks.devices = let
    deviceName = "cryptroot";
    machineId = config.networking.hostName;
  in {
    "${deviceName}" = {  # DISKO UNATTENDED BOOT
      keyFile = "/key/${machineId}-${deviceName}.keyfile";
      # both /dev/disk/by-uuid/${unlockUuid1} and findfs UUID=${unlockUuid1} work
      preOpenCommands = ''
        mkdir -m 0700 -p /key
        sleep 2 # To make sure the usb key has been loaded
        mount -n -t ${unlockDisk1.fs} -o ro `findfs ${unlockDisk1.tag}=${unlockDisk1.value}` /key || mount -n -t ${unlockDisk2.fs} -o ro `findfs ${unlockDisk2.tag}=${unlockDisk2.value}` /key
      '';
      postOpenCommands = ''
        umount /key
      '';
      fallbackToPassword = true;
    };
  };
}
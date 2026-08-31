{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  boot.loader.grub.device = "/dev/vda";
  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "xen_blkfront" "vmw_pvscsi" ];
  boot.initrd.kernelModules = [ "nvme" ];
  fileSystems."/" = {
    device = "/dev/vda1";
    fsType = "ext4";
  };

  # DigitalOcean's cloud image uses an ext4 XBOOTLDR partition.  Declare it
  # explicitly so systemd-gpt-auto-generator does not incorrectly mount it as
  # vfat after switching from the bootstrap NixOS generation.
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/3688c225-cd18-4633-bbc4-c62e00c21b95";
    fsType = "ext4";
  };
}

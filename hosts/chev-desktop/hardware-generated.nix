{
  dotfiles.desktop.efiPartuuid = "7f6d7410-a2f3-4978-9274-eb0390377936";
  dotfiles.desktop.ipadDisplay.connector = "DP-2";

  fileSystems."/data" = {
    device = "/dev/disk/by-uuid/cdff4ba1-995d-418c-ad29-a5808bf40b85";
    fsType = "btrfs";
    options = [
      "subvol=@data"
      "compress=zstd:3"
      "noatime"
      "discard=async"
      "nofail"
    ];
  };
}

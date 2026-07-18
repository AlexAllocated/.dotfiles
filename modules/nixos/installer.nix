{
  lib,
  pkgs,
  self,
  ...
}:
{
  imports = [ ./migration-tools.nix ];

  boot = {
    # The internal installer stores the verified ISO as a regular file on its
    # FAT32 ESP. The classic stage-1 initrd implements the generated GRUB
    # findiso= path; the systemd initrd currently ignores that argument and
    # attempts to mount the FAT volume itself as ISO9660.
    initrd.systemd.enable = lib.mkForce false;
    zfs.forceImportRoot = false;
  };

  networking = {
    hostName = "chev-installer";
    networkmanager.enable = true;
  };

  services = {
    desktopManager.plasma6 = {
      enable = true;
      enableQt5Integration = false;
    };
    displayManager = {
      sddm.enable = lib.mkForce false;
      plasma-login-manager.enable = true;
      autoLogin = {
        enable = true;
        user = "nixos";
      };
    };
  };

  users.users.nixos.extraGroups = [ "networkmanager" ];

  dotfiles.migrationTools = {
    enable = true;
    source = self.outPath;
    installCommand = true;
    rescue = {
      enable = true;
      user = "nixos";
    };
  };

  environment.systemPackages = with pkgs; [
    btrfs-progs
    dosfstools
    gparted
    jq
    ntfs3g
    rsync
  ];

  isoImage = {
    edition = lib.mkDefault "chev-internal";
    volumeID = "NIXOS_ISO";
  };

  system.activationScripts.chevInstallerDesktop = ''
    desktop=/home/nixos/Desktop
    install -d -m 0755 -o nixos -g users "$desktop"

    cat > "$desktop/Resume Migration.desktop" <<'EOF'
    [Desktop Entry]
    Type=Application
    Name=Resume Migration
    Comment=Verify the handoff capsule and resume its Codex thread
    Exec=konsole -e resume-migration
    Icon=utilities-terminal
    Terminal=false
    EOF

    cat > "$desktop/Install chev-desktop.desktop" <<'EOF'
    [Desktop Entry]
    Type=Application
    Name=Install chev-desktop
    Comment=Run the confirmation-gated native NixOS installer
    Exec=konsole -e install-chev-desktop --help
    Icon=drive-harddisk
    Terminal=false
    EOF

    chown nixos:users "$desktop"/*.desktop
    chmod 0755 "$desktop"/*.desktop
  '';
}

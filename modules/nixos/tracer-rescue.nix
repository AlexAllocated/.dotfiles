{
  lib,
  pkgs,
  self,
  toolPkgs,
  ...
}:
let
  rescueCodex = import ../../packages/codex.nix { inherit lib pkgs; };
in
{
  nixpkgs.config.allowUnfree = true;

  imports = [ ./tracer-tools.nix ];

  boot = {
    initrd = {
      availableKernelModules = [
        "ahci"
        "nvme"
        "sd_mod"
        "uas"
        "usb_storage"
        "vfat"
        "xhci_pci"
      ];
      kernelModules = lib.mkForce [
        "dm_mod"
        "ext4"
        "loop"
        "nls_cp437"
        "nls_iso8859-1"
        "overlay"
        "vfat"
      ];
      systemd.enable = true;
    };
    kernelModules = [ "uhid" ];
    zfs.forceImportRoot = false;
  };

  lib.isoFileSystems = {
    "/iso" = lib.mkForce {
      device = "/dev/disk/by-label/NIXOS_ISO";
      fsType = "auto";
      neededForBoot = true;
      noCheck = true;
    };
    "/home" = {
      device = "/dev/disk/by-partlabel/TRACER_RESCUE_DATA";
      fsType = "btrfs";
      options = [
        "subvol=@home"
        "compress=zstd:3"
        "noatime"
        "discard=async"
      ];
    };
    "/persist" = {
      device = "/dev/disk/by-partlabel/TRACER_RESCUE_DATA";
      fsType = "btrfs";
      options = [
        "subvol=@state"
        "compress=zstd:3"
        "noatime"
        "discard=async"
      ];
    };
    "/var/lib/NetworkManager" = {
      device = "/dev/disk/by-partlabel/TRACER_RESCUE_DATA";
      fsType = "btrfs";
      options = [
        "subvol=@networkmanager"
        "compress=zstd:3"
        "noatime"
        "discard=async"
      ];
    };
    "/etc/NetworkManager/system-connections" = {
      device = "/dev/disk/by-partlabel/TRACER_RESCUE_DATA";
      fsType = "btrfs";
      options = [
        "subvol=@network-connections"
        "compress=zstd:3"
        "noatime"
        "discard=async"
      ];
    };
  };

  networking = {
    hostName = "tracer-rescue";
    networkmanager.enable = true;
    firewall.allowedTCPPorts = [ 22 ];
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
        user = "alx";
      };
    };
    openssh = {
      enable = true;
      startWhenNeeded = false;
      openFirewall = false;
      hostKeys = [
        {
          path = "/persist/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
      settings = {
        AllowUsers = [ "alx" ];
        KbdInteractiveAuthentication = false;
        PasswordAuthentication = false;
        PermitRootLogin = "no";
        PubkeyAuthentication = true;
      };
    };
    xserver.videoDrivers = [ "nvidia" ];
    xe-guest-utilities.enable = lib.mkForce false;
  };
  systemd.services.sshd.unitConfig.RequiresMountsFor = [ "/persist" ];

  hardware = {
    enableRedistributableFirmware = true;
    graphics = {
      enable = true;
      enable32Bit = true;
    };
    nvidia = {
      modesetting.enable = true;
      open = true;
      package = pkgs.linuxPackages.nvidiaPackages.stable;
      powerManagement.enable = true;
    };
  };

  users = {
    defaultUserShell = pkgs.zsh;
    users.alx = {
      isNormalUser = true;
      uid = 1000;
      description = "Alex";
      home = "/home/alx";
      createHome = true;
      extraGroups = [
        "audio"
        "input"
        "networkmanager"
        "video"
        "wheel"
      ];
    };
  };
  programs.zsh.enable = true;

  security.sudo.wheelNeedsPassword = false;
  security.rtkit.enable = true;

  dotfiles.tracerTools = {
    enable = true;
    source = self.outPath;
    rescueMode = true;
  };

  environment.systemPackages = with pkgs; [
    btrfs-progs
    cryptsetup
    curl
    dmidecode
    dosfstools
    ethtool
    fio
    git
    gparted
    gptfdisk
    hdparm
    iperf3
    jq
    lm_sensors
    memtest86plus
    nvme-cli
    parted
    pciutils
    rsync
    smartmontools
    stress-ng
    tmux
    usbutils
    util-linux
    rescueCodex
  ];

  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 3d";
  };

  isoImage = {
    edition = lib.mkDefault "tracer-rescue";
    volumeID = "NIXOS_ISO";
  };

  system.activationScripts.tracerRescueDesktop = lib.stringAfter [ "users" ] ''
    desktop=/home/alx/Desktop
    install -d -m 0755 -o alx -g users "$desktop"

    cat >"$desktop/Resume Tracer Migration.desktop" <<'EOF'
    [Desktop Entry]
    Type=Application
    Name=Resume Tracer Migration
    Comment=Resume the Codex migration conversation
    Exec=konsole -e resume-tracer
    Icon=utilities-terminal
    Terminal=false
    EOF

    cat >"$desktop/Tracer Diagnostics.desktop" <<'EOF'
    [Desktop Entry]
    Type=Application
    Name=Tracer Diagnostics
    Comment=Inspect hardware, storage, networking, and failed units
    Exec=konsole -e sh -lc 'tracer-diagnostics; read -r'
    Icon=utilities-system-monitor
    Terminal=false
    EOF

    cat >"$desktop/Install Tracer.desktop" <<'EOF'
    [Desktop Entry]
    Type=Application
    Name=Install Tracer
    Comment=Show the confirmation-gated Tracer installer usage
    Exec=konsole -e install-tracer --help
    Icon=drive-harddisk
    Terminal=false
    EOF

    chown alx:users "$desktop"/*.desktop
    chmod 0755 "$desktop"/*.desktop
  '';

  system.stateVersion = "26.05";
}

{
  config,
  lib,
  pkgs,
  ...
}:
{
  lib.isoFileSystems = {
    "/home" = lib.mkForce {
      fsType = "tmpfs";
      options = [ "mode=0755" ];
      neededForBoot = true;
    };
    "/persist" = lib.mkForce {
      fsType = "tmpfs";
      options = [ "mode=0700" ];
      neededForBoot = true;
    };
    "/var/lib/NetworkManager" = lib.mkForce {
      fsType = "tmpfs";
      options = [ "mode=0700" ];
      neededForBoot = true;
    };
    "/etc/NetworkManager/system-connections" = lib.mkForce {
      fsType = "tmpfs";
      options = [ "mode=0700" ];
      neededForBoot = true;
    };
    "/media/tracer" = {
      device = "/dev/disk/by-label/TRACERDATA";
      fsType = "auto";
      options = [
        "rw"
        "noexec"
        "nosuid"
        "nodev"
        "umask=0077"
        "uid=1000"
        "gid=100"
      ];
      neededForBoot = true;
      noCheck = true;
    };
  };

  boot.initrd.availableKernelModules = [ "exfat" ];
  boot.initrd.systemd.services.tracer-media-ready = {
    description = "Wait for boot media device discovery before mounting rescue data";
    requiredBy = [ "sysroot-media-tracer.mount" ];
    before = [ "sysroot-media-tracer.mount" ];
    after = [ "sysroot-iso.mount" ];
    requires = [ "sysroot-iso.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    script = ''
      ${config.boot.initrd.systemd.package}/bin/udevadm settle --timeout=60
      if test -b /dev/mapper/ventoy; then
        device=$(${pkgs.coreutils}/bin/readlink -f /dev/disk/by-label/TRACERDATA)
        test -f "/sys/class/block/''${device##*/}/dm/name"
      fi
    '';
  };
  boot.loader.timeout = lib.mkForce 3;
  users.users.alx.hashedPasswordFile = "/media/tracer/remote-seed/accounts/alx-password.hash";
  networking.hostName = lib.mkForce "tracer";
  networking.networkmanager.ensureProfiles.profiles.tracer-ethernet = {
    connection = {
      id = "tracer-ethernet";
      type = "ethernet";
      autoconnect = true;
      autoconnect-priority = 100;
    };
    ipv4 = {
      method = "manual";
      address1 = "192.168.0.69/24,192.168.0.1";
      dns = "1.1.1.1;8.8.8.8;";
    };
    ipv6.method = "auto";
  };

  services.avahi = {
    enable = true;
    publish.enable = true;
    publish.userServices = true;
    openFirewall = true;
  };
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
  services.sunshine = {
    enable = true;
    autoStart = true;
    capSysAdmin = true;
    openFirewall = true;
    settings = {
      sunshine_name = "Tracer";
      capture = "kms";
      encoder = "nvenc";
      file_state = "sunshine_state.json";
      credentials_file = "sunshine_state.json";
      cert = "credentials/cacert.pem";
      pkey = "credentials/cakey.pem";
    };
    applications.apps = [
      {
        name = "Desktop";
        image-path = "desktop.png";
      }
    ];
  };
  systemd.user.services.sunshine.serviceConfig = {
    Restart = lib.mkForce "always";
    RestartSec = lib.mkForce "5s";
  };
  systemd.user.services.sunshine.unitConfig.StartLimitIntervalSec = lib.mkForce 0;

  systemd.services.tracer-remote-seed = {
    description = "Restore private remote-access identity from migration media";
    wantedBy = [ "multi-user.target" ];
    before = [
      "sshd.service"
      "sshd-keygen.service"
      "display-manager.service"
    ];
    requiredBy = [
      "sshd.service"
      "sshd-keygen.service"
      "display-manager.service"
    ];
    unitConfig.RequiresMountsFor = [ "/media/tracer" ];
    path = [
      pkgs.coreutils
      pkgs.openssh
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      seed=/media/tracer/remote-seed
      test -s "$seed/ssh/authorized_keys"
      test -s "$seed/ssh/ssh_host_ed25519_key"
      test -s "$seed/sunshine/sunshine_state.json"
      test -s "$seed/sunshine/credentials/cacert.pem"
      test -s "$seed/sunshine/credentials/cakey.pem"
      (cd "$seed" && sha256sum --check SHA256SUMS)
      install -d -m 0700 /persist/ssh
      install -m 0600 "$seed/ssh/ssh_host_ed25519_key" /persist/ssh/ssh_host_ed25519_key
      install -m 0644 "$seed/ssh/ssh_host_ed25519_key.pub" /persist/ssh/ssh_host_ed25519_key.pub
      install -d -m 0700 -o alx -g users /home/alx /home/alx/.config /home/alx/.config/sunshine /home/alx/.ssh /home/alx/.config/sunshine/credentials
      install -m 0600 -o alx -g users "$seed/ssh/authorized_keys" /home/alx/.ssh/authorized_keys
      install -m 0600 -o alx -g users "$seed/sunshine/sunshine_state.json" /home/alx/.config/sunshine/sunshine_state.json
      install -m 0600 -o alx -g users "$seed/sunshine/credentials/cacert.pem" /home/alx/.config/sunshine/credentials/cacert.pem
      install -m 0600 -o alx -g users "$seed/sunshine/credentials/cakey.pem" /home/alx/.config/sunshine/credentials/cakey.pem
    '';
  };

  systemd.services.tracer-boot-report = {
    description = "Save rescue boot diagnostics on migration media";
    after = [ "local-fs.target" ];
    unitConfig.RequiresMountsFor = [ "/media/tracer" ];
    serviceConfig = {
      Type = "oneshot";
      UMask = "0077";
    };
    path = [
      pkgs.coreutils
      pkgs.systemd
      pkgs.util-linux
    ];
    script = ''
      report=/media/tracer/NixOS-Migration/boot-logs/$(cat /proc/sys/kernel/random/boot_id)
      install -d -m 0700 "$report"
      journalctl --boot --no-pager --output=short-monotonic > "$report/journal.txt.tmp"
      mv "$report/journal.txt.tmp" "$report/journal.txt"
      systemctl --failed --no-pager > "$report/failed-units.txt"
      findmnt --real > "$report/mounts.txt"
      stat -c '%U:%G %a %n' /home /home/alx /home/alx/.config > "$report/home-permissions.txt"
      sync -f "$report"
    '';
  };
  systemd.timers.tracer-boot-report = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "2min";
    };
  };

  isoImage.edition = lib.mkForce "tracer-remote-rescue";
  environment.systemPackages = [ pkgs.exfatprogs ];
}

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.amps;
  account = config.users.users.${cfg.user};
  packages = import ../../packages/amps { inherit pkgs lib; };
  nvidia = pkgs.callPackage ../../packages/amps/nvidia-linux.nix { };
  filters = import ../../packages/amps/pipewire-spatial.nix { inherit pkgs; };
  spatial = pkgs.writeText "amps-spatial.json" (
    builtins.toJSON {
      game = filters.gameBus.args;
      music = filters.musicBus.args;
    }
  );
  state = "${account.home}/.config/amps";
  runtime = "/run/user/${toString account.uid}";
  ui = pkgs.symlinkJoin {
    name = "amps-desktop";
    paths = [ packages.ui ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/amps-ui" \
        --prefix PATH : ${
          lib.makeBinPath [
            pkgs.pipewire
            pkgs.wireplumber
            pkgs.systemd
          ]
        } \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.libayatana-appindicator ]}
    '';
  };
in
{
  options.dotfiles.amps = {
    enable = lib.mkEnableOption "AMPS system audio engine and desktop controls";
    user = lib.mkOption { type = lib.types.str; };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.user != "root" && account.uid != null;
        message = "AMPS needs an existing non-root user with a fixed UID.";
      }
    ];
    users.users.${cfg.user}.linger = true;
    environment.systemPackages = [
      packages.engine
      ui
      (pkgs.makeDesktopItem {
        name = "amps";
        desktopName = "AMPS";
        genericName = "Audio Mixing and Processing Subsystem";
        exec = "${ui}/bin/amps-ui";
        icon = "amps";
        categories = [
          "AudioVideo"
          "Audio"
          "Mixer"
        ];
      })
    ];
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (subject.user === ${builtins.toJSON cfg.user} &&
            action.id === "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") === "amps.service" &&
            ["start", "stop", "restart"].indexOf(action.lookup("verb")) !== -1) {
          return polkit.Result.YES;
        }
      });
    '';
    services.pipewire.wireplumber = {
      extraScripts."amps/routing.lua" = builtins.readFile ../../packages/amps/pipewire-routing.lua;
      extraConfig."90-amps-routing" = {
        "wireplumber.components" = [
          {
            name = "amps/routing.lua";
            type = "script/lua";
            provides = "hooks.amps-routing";
          }
        ];
        "wireplumber.profiles".main."hooks.amps-routing" = "required";
      };
    };
    systemd.services.amps = {
      description = "Audio Mixing and Processing Subsystem";
      wantedBy = [ "multi-user.target" ];
      wants = [ "user@${toString account.uid}.service" ];
      after = [ "user@${toString account.uid}.service" ];
      path = [
        pkgs.pipewire
        pkgs.wireplumber
        pkgs.coreutils
        pkgs.systemd
        config.hardware.nvidia.package
      ];
      environment = {
        HOME = account.home;
        XDG_RUNTIME_DIR = runtime;
        DBUS_SESSION_BUS_ADDRESS = "unix:path=${runtime}/bus";
        AMPS_DEEPFILTER_PLUGIN = "${pkgs.deepfilternet}/lib/ladspa/libdeep_filter_ladspa.so";
        AMPS_NVIDIA_PLUGIN = "${nvidia}/lib/liblinux_broadcast_afx_ladspa.so";
        AMPS_SPATIAL_FILTERS = toString spatial;
        AFX_SDK_ROOT = "${nvidia}/lib/nvidia";
        LINUX_BROADCAST_EFFECT = "noise";
        LD_LIBRARY_PATH = "/run/opengl-driver/lib:${nvidia}/lib/nvidia/external/cuda/lib:${nvidia}/lib/nvidia/features/denoiser/lib";
      };
      preStart = ''
        install -d -m 700 ${lib.escapeShellArg state}
        if ! test -e ${lib.escapeShellArg "${state}/config.toml"}; then
          ${packages.engine}/bin/amps example-config > ${lib.escapeShellArg "${state}/config.toml"}
        fi
        for attempt in $(seq 1 60); do
          if test -S ${runtime}/pipewire-0; then exit 0; fi
          sleep 1
        done
        exit 1
      '';
      serviceConfig = {
        User = cfg.user;
        ExecStart = "${packages.engine}/bin/amps --config ${state}/config.toml run";
        Restart = "on-failure";
        RestartSec = 3;
        KillSignal = "SIGINT";
        TimeoutStopSec = 15;
        UMask = "0077";
      };
    };
    systemd.user.services.amps-ui = {
      description = "AMPS tray and audio graph";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${ui}/bin/amps-ui --tray";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}

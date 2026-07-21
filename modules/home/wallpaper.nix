{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.wallpaper;
  enabled = pkgs.stdenv.hostPlatform.isLinux && cfg.enable;
in
{
  imports = [ ./core.nix ];

  options.dotfiles.wallpaper = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.dotfiles.profile == "nixos-desktop";
      description = "Install and assign the workstation wallpaper by physical output.";
    };

    source = lib.mkOption {
      type = lib.types.path;
      default = ../../assets/wallpapers/pixel-meadow-hex-gruvbox-3440x1440.png;
      description = "Source image installed as the workstation wallpaper.";
    };

    fileName = lib.mkOption {
      type = lib.types.strMatching "^[A-Za-z0-9._+-]+[.]png$";
      default = "pixel-meadow-hex-gruvbox-3440x1440.png";
      description = "Stable installed wallpaper filename.";
    };

    installedPath = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${config.xdg.dataHome}/wallpapers/dotfiles/${cfg.fileName}";
      description = "Stable user-visible path to the installed wallpaper.";
    };

    connector = lib.mkOption {
      type = lib.types.strMatching "^[A-Za-z0-9._-]+$";
      default = "DP-1";
      description = "Physical output that receives the ultrawide wallpaper.";
    };

    logicalWidth = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3440;
      description = "Logical width used to identify the output in Plasma.";
    };

    logicalHeight = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1440;
      description = "Logical height used to identify the output in Plasma.";
    };

    ipad = {
      connector = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "^[A-Za-z0-9._-]+$");
        default = null;
        example = "DP-2";
        description = "Optional iPad dummy output that receives the 4:3 wallpaper.";
      };

      source = lib.mkOption {
        type = lib.types.path;
        default = ../../assets/wallpapers/pixel-meadow-hex-gruvbox-2732x2048.png;
        description = "Source image installed as the iPad dummy wallpaper.";
      };

      fileName = lib.mkOption {
        type = lib.types.strMatching "^[A-Za-z0-9._+-]+[.]png$";
        default = "pixel-meadow-hex-gruvbox-2732x2048.png";
        description = "Stable installed filename for the iPad dummy wallpaper.";
      };

      installedPath = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${config.xdg.dataHome}/wallpapers/dotfiles/${cfg.ipad.fileName}";
        description = "Stable user-visible path to the installed iPad wallpaper.";
      };

      logicalWidth = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1561;
        description = "Scaled logical width used to identify the iPad output in Plasma.";
      };

      logicalHeight = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1170;
        description = "Scaled logical height used to identify the iPad output in Plasma.";
      };
    };
  };

  config = lib.mkIf enabled {
    # Noctalia deliberately rejects symlinks for wallpaper sources. Home
    # Manager normally links dataFile entries into the Nix store, so install a
    # real immutable-by-convention copy at the stable desktop-facing path.
    home.activation.installDesktopWallpaper = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${lib.getExe' pkgs.coreutils "mkdir"} -p -- ${lib.escapeShellArg "${config.xdg.dataHome}/wallpapers/dotfiles"}
      run ${lib.getExe' pkgs.coreutils "rm"} -f -- ${lib.escapeShellArg cfg.installedPath}
      run ${lib.getExe' pkgs.coreutils "install"} -m 0644 -- ${lib.escapeShellArg (toString cfg.source)} ${lib.escapeShellArg cfg.installedPath}
      ${lib.optionalString (cfg.ipad.connector != null) ''
        run ${lib.getExe' pkgs.coreutils "rm"} -f -- ${lib.escapeShellArg cfg.ipad.installedPath}
        run ${lib.getExe' pkgs.coreutils "install"} -m 0644 -- ${lib.escapeShellArg (toString cfg.ipad.source)} ${lib.escapeShellArg cfg.ipad.installedPath}
      ''}
    '';
  };
}

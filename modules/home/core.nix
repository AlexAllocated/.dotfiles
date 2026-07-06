{
  config,
  lib,
  pkgs,
  profile ? "linux",
  ...
}:
{
  options.dotfiles = {
    profile = lib.mkOption {
      type = lib.types.str;
      default = profile;
      description = "Named dotfiles target profile.";
    };

    userName = lib.mkOption {
      type = lib.types.str;
      default = "alex";
      description = "Default user name for personal dotfiles modules.";
    };

    fullName = lib.mkOption {
      type = lib.types.str;
      default = "Alex";
      description = "Default Git/user display name.";
    };

    userEmail = lib.mkOption {
      type = lib.types.str;
      default = "Alex@HiveTech.ai";
      description = "Default Git/user email.";
    };

    source = lib.mkOption {
      type = lib.types.path;
      default = ../..;
      description = "Immutable dotfiles source used for linked configuration.";
    };

    mutableSource = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional mutable dotfiles checkout used instead of the flake source.";
    };
  };

  config = {
    home.stateVersion = "26.05";
    programs.home-manager.enable = true;
    xdg.enable = true;

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    home.sessionVariables = {
      HOMEBREW_NO_ENV_HINTS = "1";
      MS_COG_SVC_SPEECH_SKIP_BINDGEN = "1";
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      CURL_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    };

    home.sessionPath = [
      "$HOME/.cache/.bun/bin"
      "$HOME/.bun/bin"
      "$HOME/.cargo/bin"
      "$HOME/bin"
      "$HOME/.local/bin"
      "$HOME/go/bin"
    ];
  };
}

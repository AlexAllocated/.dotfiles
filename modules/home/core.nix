{
  config,
  lib,
  pkgs,
  profile ? "generic",
  ...
}:
{
  options.dotfiles = {
    profile = lib.mkOption {
      type = lib.types.str;
      default = profile;
      description = "Named dotfiles target profile.";
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
    programs.home-manager.enable = true;
    xdg.enable = true;

    home.sessionVariables = {
      HOMEBREW_NO_ENV_HINTS = "1";
      MS_COG_SVC_SPEECH_SKIP_BINDGEN = "1";
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      CURL_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
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

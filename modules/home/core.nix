{
  config,
  lib,
  pkgs,
  profile ? "generic",
  ...
}:
let
  firefoxExternalLinkHandler = pkgs.writeShellApplication {
    name = "dotfiles-open-firefox-link";
    runtimeInputs = [
      pkgs.firefox
      pkgs.jq
      pkgs.niri
      pkgs.systemd
    ];
    text = ''
      user_environment_value() {
        local line variable
        variable="$1"
        while IFS= read -r line; do
          if [[ "$line" == "$variable="* ]]; then
            printf '%s\n' "''${line#*=}"
            return 0
          fi
        done < <(systemctl --user show-environment 2>/dev/null || true)
        return 0
      }

      focus_niri_firefox() {
        local window_id
        if [[ -z "''${NIRI_SOCKET:-}" ]]; then
          NIRI_SOCKET="$(user_environment_value NIRI_SOCKET)"
          export NIRI_SOCKET
        fi
        [[ -n "''${NIRI_SOCKET:-}" ]] || return 1

        window_id="$(
          niri msg --json windows 2>/dev/null \
            | jq -r '
                [
                  .[]
                  | select(
                      ((.app_id // "") | ascii_downcase) == "firefox"
                      and ((.title // "") | ascii_downcase) != "picture-in-picture"
                    )
                ]
                | sort_by([.focus_timestamp.secs // 0, .focus_timestamp.nanos // 0])
                | (last // {})
                | .id // empty
              '
        )" || return 1
        [[ "$window_id" =~ ^[0-9]+$ ]] || return 1
        niri msg action focus-window --id "$window_id" >/dev/null 2>&1
      }

      focus_mango_firefox() {
        local window_id
        if [[ -z "''${MANGO_INSTANCE_SIGNATURE:-}" ]]; then
          MANGO_INSTANCE_SIGNATURE="$(user_environment_value MANGO_INSTANCE_SIGNATURE)"
          export MANGO_INSTANCE_SIGNATURE
        fi
        [[ -n "''${MANGO_INSTANCE_SIGNATURE:-}" ]] || return 1
        command -v mmsg >/dev/null 2>&1 || return 1

        window_id="$(
          mmsg get all-clients 2>/dev/null \
            | jq -r '
                [
                  .clients[]
                  | select(
                      ((.appid // "") | ascii_downcase) == "firefox"
                      and ((.is_swallowedby // false) | not)
                    )
                ]
                | (map(select(.is_focused)) + map(select(.is_visible)) + .)
                | ((first // {}) | .id // empty)
              '
        )" || return 1
        [[ -n "$window_id" ]] || return 1
        mmsg dispatch focusid "client,$window_id" >/dev/null 2>&1
      }

      focus_firefox() {
        local desktop
        desktop="''${XDG_CURRENT_DESKTOP:-}"
        desktop="''${desktop,,}"

        if [[ "$desktop" == *niri* ]]; then
          focus_niri_firefox
        elif [[ "$desktop" == *mango* ]]; then
          focus_mango_firefox
        elif [[ -n "''${NIRI_SOCKET:-}" ]]; then
          focus_niri_firefox
        elif [[ -n "''${MANGO_INSTANCE_SIGNATURE:-}" ]]; then
          focus_mango_firefox
        else
          return 1
        fi
      }

      browser_was_running=false
      if focus_firefox; then
        browser_was_running=true
      fi

      firefox --name firefox "$@" >/dev/null 2>&1 &
      launcher_pid=$!

      for _ in {1..40}; do
        sleep 0.05
        if focus_firefox; then
          if [[ "$browser_was_running" == false ]] || ! kill -0 "$launcher_pid" 2>/dev/null; then
            exit 0
          fi
        fi
      done

      focus_firefox || true
    '';
  };
in
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
    xdg = {
      enable = true;
      desktopEntries = lib.mkIf (profile == "nixos-desktop") {
        firefox-focused = {
          name = "Firefox external link handler";
          genericName = "Web Browser";
          exec = "${lib.getExe firefoxExternalLinkHandler} %U";
          icon = "firefox";
          terminal = false;
          noDisplay = true;
          startupNotify = true;
          categories = [
            "Network"
            "WebBrowser"
          ];
          mimeType = [
            "text/html"
            "x-scheme-handler/http"
            "x-scheme-handler/https"
          ];
        };
      };
      mimeApps = lib.mkIf (profile == "nixos-desktop") {
        enable = true;
        defaultApplications = {
          "text/html" = [ "firefox-focused.desktop" ];
          "x-scheme-handler/http" = [ "firefox-focused.desktop" ];
          "x-scheme-handler/https" = [ "firefox-focused.desktop" ];
        };
      };
    };

    home.sessionVariables = {
      HOMEBREW_NO_ENV_HINTS = "1";
      MS_COG_SVC_SPEECH_SKIP_BINDGEN = "1";
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      CURL_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };

    home.sessionPath = [
      "$HOME/.local/share/mise/shims"
      "$HOME/.cache/.bun/bin"
      "$HOME/.bun/bin"
      "$HOME/.cargo/bin"
      "$HOME/bin"
      "$HOME/.local/bin"
      "$HOME/go/bin"
    ];
  };
}

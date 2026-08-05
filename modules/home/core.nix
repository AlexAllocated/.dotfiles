{
  config,
  lib,
  pkgs,
  profile ? "generic",
  ...
}:
let
  defaultBrowserDesktop = "google-chrome.desktop";
  qbittorrentGruvboxTheme = pkgs.fetchurl {
    url = "https://github.com/MahdiMirzadeh/qbittorrent/releases/download/v0.6.6/gruvbox-dark.qbtheme";
    hash = "sha256-9OMTljqDhr4CFhdd185RVFOEGC0ZRUV2zPkg8oWOtwU=";
  };
  qbittorrentSearchPlugins = pkgs.fetchFromGitHub {
    owner = "qbittorrent";
    repo = "search-plugins";
    rev = "62f296ed47010ab0ea9dbd43257a1a20025d1d1a";
    hash = "sha256-ncY7iK6lTIbF3h1Ts+BC2YHT8sWX4XRSi3vbORSQoMw=";
  };
  qbittorrentSearchPluginNames = [
    "eztv"
    "limetorrents"
    "piratebay"
    "solidtorrents"
    "torlock"
    "torrentproject"
    "torrentscsv"
  ];
  bittorrentMimeTypes = [
    "application/x-bittorrent"
    "x-scheme-handler/magnet"
  ];
  pdfMimeTypes = [
    "application/pdf"
    "application/x-bzpdf"
    "application/x-ext-pdf"
    "application/x-gzpdf"
    "application/x-xzpdf"
  ];
  loupeImageMimeTypes = [
    "image/apng"
    "image/avif"
    "image/bmp"
    "image/gif"
    "image/heic"
    "image/jp2"
    "image/jxl"
    "image/jpeg"
    "image/png"
    "image/qoi"
    "image/svg+xml"
    "image/svg+xml-compressed"
    "image/tiff"
    "image/vnd.microsoft.icon"
    "image/webp"
    "image/x-dds"
    "image/x-exr"
    "image/x-portable-anymap"
    "image/x-portable-bitmap"
    "image/x-portable-graymap"
    "image/x-portable-pixmap"
    "image/x-qoi"
    "image/x-tga"
    "image/x-win-bitmap"
    "image/x-xbitmap"
    "image/x-xpixmap"
  ];
  vlcVideoMimeTypes = [
    "application/mxf"
    "application/vnd.rn-realmedia"
    "application/vnd.rn-realmedia-vbr"
    "application/x-extension-mp4"
    "application/x-flash-video"
    "application/x-matroska"
    "application/x-quicktime-media-link"
    "application/x-quicktimeplayer"
    "video/3gp"
    "video/3gpp"
    "video/3gpp2"
    "video/annodex"
    "video/avi"
    "video/divx"
    "video/dv"
    "video/fli"
    "video/flv"
    "video/isivideo"
    "video/mj2"
    "video/mlt-playlist"
    "video/mp2t"
    "video/mp4"
    "video/mp4v-es"
    "video/mpeg"
    "video/mpeg-system"
    "video/msvideo"
    "video/ogg"
    "video/quicktime"
    "video/vnd.avi"
    "video/vnd.divx"
    "video/vnd.mpegurl"
    "video/vnd.radgamettools.bink"
    "video/vnd.radgamettools.smacker"
    "video/vnd.rn-realvideo"
    "video/vnd.vivo"
    "video/vnd.youtube.yt"
    "video/wavelet"
    "video/webm"
    "video/x-anim"
    "video/x-avi"
    "video/x-flc"
    "video/x-fli"
    "video/x-flic"
    "video/x-flv"
    "video/x-javafx"
    "video/x-m4v"
    "video/x-matroska"
    "video/x-matroska-3d"
    "video/x-mjpeg"
    "video/x-mng"
    "video/x-mpeg"
    "video/x-mpeg-system"
    "video/x-mpeg2"
    "video/x-ms-asf"
    "video/x-ms-asf-plugin"
    "video/x-ms-asx"
    "video/x-ms-wm"
    "video/x-ms-wmp"
    "video/x-ms-wmv"
    "video/x-ms-wmx"
    "video/x-ms-wvx"
    "video/x-msvideo"
    "video/x-nsv"
    "video/x-ogm"
    "video/x-ogm+ogg"
    "video/x-sgi-movie"
    "video/x-theora"
    "video/x-theora+ogg"
  ];
  scaledVlc = pkgs.writeShellApplication {
    name = "dotfiles-vlc";
    text = ''
      scale=""
      if [[ -n "''${NIRI_SOCKET:-}" ]]; then
        scale="$(
          ${lib.getExe pkgs.niri} msg --json focused-output 2>/dev/null \
            | ${lib.getExe pkgs.jq} -r '.logical.scale // empty' \
            || true
        )"
      fi

      if [[ -n "$scale" ]]; then
        export QT_SCALE_FACTOR="$scale"
      fi

      exec ${lib.getExe pkgs.vlc} "$@"
    '';
  };
  scaledDavinciResolve = pkgs.writeShellApplication {
    name = "dotfiles-davinci-resolve";
    text = ''
      scale=""
      display_scale=""
      if [[ -n "''${NIRI_SOCKET:-}" ]]; then
        scale="$(
          ${lib.getExe pkgs.niri} msg --json focused-output 2>/dev/null \
            | ${lib.getExe pkgs.jq} -r '.logical.scale // empty' \
            || true
        )"
      fi

      if [[ -n "$scale" ]]; then
        # Resolve ignores Qt's fractional scale variables and exposes only
        # 100%, 150%, and 200% UI sizes on Linux. Match its nearest useful
        # native size to the output where it is launched: 100% on the LG and
        # 150% on the 1.75x Sunshine/iPad output.
        display_scale="$(${lib.getExe pkgs.jq} -nr --argjson scale "$scale" '
          if $scale >= 2 then 200
          elif $scale >= 1.25 then 150
          else 100
          end
        ')"
      fi

      apply_display_scale() {
        local preferences
        [[ -n "$display_scale" ]] || return 0
        preferences="''${XDG_DATA_HOME:-$HOME/.local/share}/DaVinciResolve/configs/config.user.xml"
        [[ -f "$preferences" ]] || return 0
        ${lib.getExe pkgs.gnused} --in-place --regexp-extended \
          "s#<DisplayScale>[0-9]+</DisplayScale>#<DisplayScale>$display_scale</DisplayScale>#" \
          "$preferences"
      }

      apply_display_scale
      ${pkgs.davinci-resolve}/bin/davinci-resolve "$@"
      status=$?
      # A first launch creates the preferences file only while Resolve exits.
      apply_display_scale
      exit "$status"
    '';
  };
  firefoxExternalLinkHandler = pkgs.writeShellApplication {
    name = "dotfiles-open-firefox-link";
    runtimeInputs = [
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
        if [[ -z "$desktop" ]]; then
          desktop="$(user_environment_value XDG_CURRENT_DESKTOP)"
        fi
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

      # The NixOS package is wrapped with the native-Wayland GTK schema
      # contract. Use that canonical launcher instead of capturing a second
      # Firefox package in this helper's private PATH.
      /run/current-system/sw/bin/firefox --name firefox "$@" >/dev/null 2>&1 &
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
  chromeExternalLinkHandler = pkgs.writeShellApplication {
    name = "dotfiles-open-chrome-link";
    runtimeInputs = [
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

      focus_niri_chrome() {
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
                      ((.app_id // "") | ascii_downcase) == "google-chrome"
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

      focus_mango_chrome() {
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
                      ((.appid // "") | ascii_downcase) == "google-chrome"
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

      focus_chrome() {
        local desktop
        desktop="''${XDG_CURRENT_DESKTOP:-}"
        if [[ -z "$desktop" ]]; then
          desktop="$(user_environment_value XDG_CURRENT_DESKTOP)"
        fi
        desktop="''${desktop,,}"

        if [[ "$desktop" == *niri* ]]; then
          focus_niri_chrome
        elif [[ "$desktop" == *mango* ]]; then
          focus_mango_chrome
        elif [[ -n "''${NIRI_SOCKET:-}" ]]; then
          focus_niri_chrome
        elif [[ -n "''${MANGO_INSTANCE_SIGNATURE:-}" ]]; then
          focus_mango_chrome
        else
          return 1
        fi
      }

      browser_was_running=false
      if focus_chrome; then
        browser_was_running=true
      fi

      /run/current-system/sw/bin/google-chrome "$@" >/dev/null 2>&1 &
      launcher_pid=$!

      for _ in {1..40}; do
        sleep 0.05
        if focus_chrome; then
          if [[ "$browser_was_running" == false ]] || ! kill -0 "$launcher_pid" 2>/dev/null; then
            exit 0
          fi
        fi
      done

      focus_chrome || true
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
      configFile."qBittorrent/themes/gruvbox-dark.qbtheme" = lib.mkIf (profile == "nixos-desktop") {
        source = qbittorrentGruvboxTheme;
      };
      dataFile = lib.mkIf (profile == "nixos-desktop") (
        lib.listToAttrs (
          map (pluginName: {
            name = "qBittorrent/nova3/engines/${pluginName}.py";
            value.source = "${qbittorrentSearchPlugins}/nova3/engines/${pluginName}.py";
          }) qbittorrentSearchPluginNames
        )
      );
      desktopEntries = lib.mkIf (profile == "nixos-desktop") {
        # Shadow Chrome's packaged desktop ID so it still recognizes itself
        # as the default browser while external links also focus its window.
        google-chrome = {
          name = "Google Chrome";
          genericName = "Web Browser";
          exec = "${lib.getExe chromeExternalLinkHandler} %U";
          icon = "google-chrome";
          terminal = false;
          startupNotify = true;
          categories = [
            "Network"
            "WebBrowser"
          ];
          mimeType = [
            "application/xhtml+xml"
            "text/html"
            "x-scheme-handler/http"
            "x-scheme-handler/https"
          ];
        };
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
            "application/xhtml+xml"
            "text/html"
            "x-scheme-handler/http"
            "x-scheme-handler/https"
          ];
        };
        vlc = {
          name = "VLC media player";
          genericName = "Video player";
          exec = "${lib.getExe scaledVlc} --started-from-file %U";
          icon = "vlc";
          terminal = false;
          categories = [
            "AudioVideo"
            "Player"
          ];
          mimeType = vlcVideoMimeTypes;
        };
        davinci-resolve = {
          name = "DaVinci Resolve";
          genericName = "Video Editor";
          comment = "Professional video editing, color, effects and audio post-processing";
          exec = "${lib.getExe scaledDavinciResolve} %U";
          icon = "davinci-resolve";
          terminal = false;
          startupNotify = true;
          settings.StartupWMClass = "resolve";
          categories = [
            "AudioVideo"
            "AudioVideoEditing"
            "Video"
            "Graphics"
          ];
        };
      };
      mimeApps = lib.mkIf (profile == "nixos-desktop") {
        enable = true;
        associations.added = {
          "inode/directory" = [ "org.gnome.Nautilus.desktop" ];
        }
        // lib.genAttrs bittorrentMimeTypes (_: [ "org.qbittorrent.qBittorrent.desktop" ])
        // lib.genAttrs loupeImageMimeTypes (_: [ "org.gnome.Loupe.desktop" ])
        // lib.genAttrs pdfMimeTypes (_: [ "org.gnome.Papers.desktop" ])
        // lib.genAttrs vlcVideoMimeTypes (_: [ "vlc.desktop" ]);
        defaultApplications = {
          "application/xhtml+xml" = [ defaultBrowserDesktop ];
          "inode/directory" = [ "org.gnome.Nautilus.desktop" ];
          "text/html" = [ defaultBrowserDesktop ];
          "x-scheme-handler/http" = [ defaultBrowserDesktop ];
          "x-scheme-handler/https" = [ defaultBrowserDesktop ];
          "x-scheme-handler/discord" = [ "vesktop.desktop" ];
        }
        // lib.genAttrs bittorrentMimeTypes (_: [ "org.qbittorrent.qBittorrent.desktop" ])
        // lib.genAttrs loupeImageMimeTypes (_: [ "org.gnome.Loupe.desktop" ])
        // lib.genAttrs pdfMimeTypes (_: [ "org.gnome.Papers.desktop" ])
        // lib.genAttrs vlcVideoMimeTypes (_: [ "vlc.desktop" ]);
      };
    };

    home.activation.qbittorrentGruvboxTheme = lib.mkIf (profile == "nixos-desktop") (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        config_dir="${config.xdg.configHome}/qBittorrent"
        config_file="$config_dir/qBittorrent.conf"
        theme_file="$config_dir/themes/gruvbox-dark.qbtheme"

        run ${pkgs.coreutils}/bin/mkdir -p "$config_dir"
        run ${lib.getExe pkgs.crudini} --set "$config_file" Preferences 'General\CustomUIThemePath' "$theme_file"
        run ${lib.getExe pkgs.crudini} --set "$config_file" Preferences 'General\UseCustomUITheme' true
        run ${lib.getExe pkgs.crudini} --set "$config_file" Preferences 'Search\SearchEnabled' true
        run ${lib.getExe pkgs.crudini} --set "$config_file" Preferences 'Search\pythonExecutablePath' '${lib.getExe pkgs.python3}'
      ''
    );

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

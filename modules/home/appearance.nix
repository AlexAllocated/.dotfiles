{
  config,
  lib,
  pkgs,
  ...
}:
let
  workstation = config.dotfiles.profile == "nixos-desktop";
in
{
  imports = [ ./core.nix ];

  config = lib.mkIf workstation {
    home.packages = [
      pkgs.adwaita-icon-theme
      pkgs.gruvbox-dark-gtk
      pkgs.gruvbox-dark-icons-gtk
    ];

    # GTK's cursor-theme name does not install or select a compositor cursor
    # by itself. Keep the actual theme in the user profile and export the
    # matching freedesktop variables for native Wayland and XWayland clients.
    home.sessionVariables = {
      XCURSOR_SIZE = "24";
      XCURSOR_THEME = "Adwaita";
    };

    # GTK applications cannot consume Noctalia's QML palette directly. These
    # settings select the matching packaged Gruvbox theme and make dark mode
    # explicit for applications that only honor the freedesktop preference.
    xdg.configFile."gtk-3.0/settings.ini" = {
      force = true;
      text = ''
        [Settings]
        gtk-application-prefer-dark-theme=true
        gtk-button-images=true
        gtk-cursor-blink=true
        gtk-cursor-blink-time=1000
        gtk-cursor-theme-name=Adwaita
        gtk-cursor-theme-size=24
        gtk-decoration-layout=icon:minimize,maximize,close
        gtk-enable-animations=true
        gtk-font-name=Noto Sans 10
        gtk-icon-theme-name=oomox-gruvbox-dark
        gtk-menu-images=true
        gtk-primary-button-warps-slider=true
        gtk-theme-name=gruvbox-dark
        gtk-toolbar-style=3
        gtk-xft-dpi=98304
      '';
    };
    xdg.configFile."gtk-4.0/settings.ini" = {
      force = true;
      text = ''
        [Settings]
        gtk-cursor-blink=true
        gtk-cursor-blink-time=1000
        gtk-cursor-theme-name=Adwaita
        gtk-cursor-theme-size=24
        gtk-decoration-layout=icon:minimize,maximize,close
        gtk-enable-animations=true
        gtk-font-name=Noto Sans 10
        gtk-icon-theme-name=oomox-gruvbox-dark
        gtk-primary-button-warps-slider=true
        gtk-xft-dpi=98304
      '';
    };

    # Nautilus is a libadwaita application, so it deliberately ignores legacy
    # GTK themes. Override libadwaita's public palette names instead; this
    # preserves its native layout while matching Noctalia's Gruvbox colors.
    xdg.configFile."gtk-4.0/gtk.css" = {
      force = true;
      text = ''
        @define-color accent_color #b8bb26;
        @define-color accent_bg_color #b8bb26;
        @define-color accent_fg_color #1d2021;
        @define-color window_bg_color #282828;
        @define-color window_fg_color #ebdbb2;
        @define-color view_bg_color #282828;
        @define-color view_fg_color #ebdbb2;
        @define-color headerbar_bg_color #3c3836;
        @define-color headerbar_fg_color #fbf1c7;
        @define-color headerbar_border_color #57514e;
        @define-color sidebar_bg_color #282828;
        @define-color sidebar_fg_color #ebdbb2;
        @define-color card_bg_color #3c3836;
        @define-color card_fg_color #ebdbb2;
        @define-color popover_bg_color #3c3836;
        @define-color popover_fg_color #ebdbb2;
        @define-color destructive_bg_color #fb4934;
        @define-color destructive_fg_color #1d2021;
      '';
    };

    dconf.settings."org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      cursor-size = 24;
      cursor-theme = "Adwaita";
      gtk-theme = "gruvbox-dark";
      icon-theme = "oomox-gruvbox-dark";
    };
  };
}

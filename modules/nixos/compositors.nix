{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.compositors;
in
{
  options.dotfiles.compositors.nvidiaVramWorkaround = lib.mkEnableOption ''
    niri's NVIDIA free-buffer-pool workaround
  '';

  config = {
    programs = {
      hyprland = {
        enable = true;
        withUWSM = true;
        xwayland.enable = true;
      };

      niri = {
        enable = true;
        # Dolphin remains the desktop file manager; use the GTK portal instead
        # of pulling Nautilus into the workstation merely for file pickers.
        useNautilus = false;
      };
    };

    # Niri discovers this on PATH and starts it on demand for Steam, Discord,
    # WezTerm, and other X11 applications.
    environment.systemPackages = [ pkgs.xwayland-satellite ];

    # NVIDIA recommends disabling its Wayland compositor free-buffer pool for
    # niri. Without this profile, an idle session can retain roughly 1 GiB of
    # otherwise-unused VRAM.
    environment.etc."nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json" =
      lib.mkIf cfg.nvidiaVramWorkaround {
        text = builtins.toJSON {
          rules = [
            {
              pattern = {
                feature = "procname";
                matches = "niri";
              };
              profile = "Limit Free Buffer Pool On Wayland Compositors";
            }
          ];
          profiles = [
            {
              name = "Limit Free Buffer Pool On Wayland Compositors";
              settings = [
                {
                  key = "GLVidHeapReuseRatio";
                  value = 0;
                }
              ];
            }
          ];
        };
      };
  };
}

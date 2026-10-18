{
  config,
  lib,
  ...
}:
{
  options.dotfiles.bumblebeeResume.enable = lib.mkEnableOption "Alex's private Bumblebee resume services";

  config = lib.mkIf config.dotfiles.bumblebeeResume.enable {
    systemd.user.services = {
      bumblebee-resume = {
        Unit = {
          Description = "Private Bumblebee interactive resume";
          # Ordering after the target that wants this service creates a cycle
          # when the tunnel also waits for the site. Order after its pre-target.
          After = [ "graphical-session-pre.target" ];
          PartOf = [ "graphical-session.target" ];
          ConditionPathExists = [
            "%h/code/bumblebee-resume/build/index.js"
            "%h/code/bumblebee-resume/ops/run-resume.py"
            "%h/code/bumblebee-resume/ops/runtime/bin/python3"
          ];
        };
        Service = {
          Type = "simple";
          WorkingDirectory = "%h/code/bumblebee-resume";
          # Keep the private checkout's existing GC-rooted, pinned runtime.
          ExecStart = "%h/code/bumblebee-resume/ops/runtime/bin/python3 %h/code/bumblebee-resume/ops/run-resume.py";
          Restart = "on-failure";
          RestartSec = 30;
          TimeoutStopSec = 20;
          UMask = "0077";
          Environment = [ "RESUME_ORIGIN=https://bumblebee.buzz" ];
          NoNewPrivileges = true;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };

      bumblebee-resume-tunnel = {
        Unit = {
          Description = "Cloudflare Tunnel for the private Bumblebee resume";
          After = [
            "graphical-session-pre.target"
            "network-online.target"
            "bumblebee-resume.service"
          ];
          Wants = [
            "network-online.target"
            "bumblebee-resume.service"
          ];
          PartOf = [ "graphical-session.target" ];
          ConditionPathExists = [
            "%h/code/bumblebee-resume/build/index.js"
            "%h/code/bumblebee-resume/ops/runtime/bin/cloudflared"
            "%h/.config/bumblebee-resume/tunnel.yml"
          ];
        };
        Service = {
          Type = "simple";
          ExecStart = "%h/code/bumblebee-resume/ops/runtime/bin/cloudflared --no-autoupdate --config %h/.config/bumblebee-resume/tunnel.yml tunnel run";
          Restart = "on-failure";
          RestartSec = 10;
          TimeoutStopSec = 30;
          UMask = "0077";
          NoNewPrivileges = true;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}

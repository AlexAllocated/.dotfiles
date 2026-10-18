{
  config,
  lib,
  pkgs,
  ...
}:
let
  workstation = config.dotfiles.profile == "nixos-desktop";
  crudini = lib.getExe pkgs.crudini;
  recordEncoder = pkgs.writeText "obs-record-encoder.json" (
    builtins.toJSON {
      adaptive_quantization = true;
      bf = 2;
      cqp = 18;
      device = -1;
      keyint_sec = 2;
      lookahead = false;
      multipass = "disabled";
      preset = "p5";
      profile = "main";
      rate_control = "CQP";
      tune = "hq";
    }
  );
  streamEncoder = pkgs.writeText "obs-stream-encoder.json" (
    builtins.toJSON {
      bf = 2;
      bitrate = 8000;
      buffer_size = 8000;
      keyint_sec = 2;
      preset = "fast";
      profile = "high";
      rate_control = "CBR";
      tune = "";
      use_bufsize = false;
      vfr = false;
      x264opts = "threads=12";
    }
  );
in
{
  config = lib.mkIf workstation {
    home.activation.obsProductionEncoding = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      obs_root="''${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio"
      profile_root="$obs_root/basic/profiles/HiveTech_1440p"
      profile_config="$profile_root/basic.ini"
      if ${lib.getExe' pkgs.procps "pgrep"} -u "$UID" -x '.obs-wrapped.*|obs' >/dev/null; then
        echo "OBS is running; leaving its mutable production profile untouched"
      elif [[ ! -f "$profile_config" ]]; then
        echo "OBS production profile not imported; leaving other profiles untouched"
      else
        run ${crudini} --set "$profile_config" SimpleOutput StreamEncoder nvenc
        run ${crudini} --set "$profile_config" SimpleOutput RecEncoder nvenc
        run ${crudini} --set "$profile_config" AdvOut Encoder obs_x264
        run ${crudini} --set "$profile_config" AdvOut RecEncoder obs_nvenc_hevc_tex
        run ${crudini} --set "$profile_config" AdvOut Rescale true
        run ${crudini} --set "$profile_config" AdvOut RescaleRes 1920x1080
        run ${crudini} --set "$profile_config" AdvOut RecTracks 62
        run ${lib.getExe' pkgs.coreutils "install"} -m 0644 \
          ${recordEncoder} "$profile_root/recordEncoder.json"
        run ${lib.getExe' pkgs.coreutils "install"} -m 0644 \
          ${streamEncoder} "$profile_root/streamEncoder.json"
      fi
    '';
  };
}

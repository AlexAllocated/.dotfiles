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
      cqp = 20;
      device = -1;
      keyint_sec = 2;
      lookahead = false;
      multipass = "disabled";
      preset = "p3";
      profile = "high";
      rate_control = "CQP";
      tune = "hq";
    }
  );
  streamEncoder = pkgs.writeText "obs-stream-encoder.json" (
    builtins.toJSON {
      adaptive_quantization = true;
      bf = 2;
      bitrate = 6000;
      device = -1;
      keyint_sec = 2;
      lookahead = false;
      max_bitrate = 6000;
      multipass = "disabled";
      preset = "p3";
      profile = "high";
      rate_control = "CBR";
      tune = "hq";
    }
  );
in
{
  config = lib.mkIf workstation {
    # OBS owns mutable scene and profile files. Reconcile only the encoder
    # contract during activation so scenes, sources, and six-track audio
    # routing remain editable while CPU x264 cannot silently return.
    home.activation.obsHardwareEncoding = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      obs_root="''${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio"
      user_config="$obs_root/user.ini"
      profile_dir=""

      if [[ -f "$user_config" ]]; then
        profile_dir="$(${crudini} --get "$user_config" Basic ProfileDir 2>/dev/null || true)"
      fi
      [[ -n "$profile_dir" ]] || profile_dir="Untitled"

      profile_root="$obs_root/basic/profiles/$profile_dir"
      profile_config="$profile_root/basic.ini"
      if [[ ! -f "$profile_config" ]]; then
        echo "OBS profile not initialized; leaving encoder defaults for its first launch"
      else
        run ${crudini} --set "$profile_config" SimpleOutput StreamEncoder nvenc
        run ${crudini} --set "$profile_config" SimpleOutput RecEncoder nvenc
        run ${crudini} --set "$profile_config" AdvOut Encoder obs_nvenc_h264_tex
        run ${crudini} --set "$profile_config" AdvOut RecEncoder obs_nvenc_h264_tex
        run ${lib.getExe' pkgs.coreutils "install"} -m 0644 \
          ${recordEncoder} "$profile_root/recordEncoder.json"
        run ${lib.getExe' pkgs.coreutils "install"} -m 0644 \
          ${streamEncoder} "$profile_root/streamEncoder.json"
      fi
    '';
  };
}

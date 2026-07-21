{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  enabled = pkgs.stdenv.hostPlatform.isLinux && cfg.profile == "nixos-desktop";
  sourceRoot = if cfg.mutableSource != null then cfg.mutableSource else cfg.source;
  configSource = sourceRoot + "/razer/input-remapper-2/config.json";
  configTarget = "${config.xdg.configHome}/input-remapper-2/config.json";
  xmodmapSource = sourceRoot + "/razer/input-remapper-2/xmodmap.json";
  xmodmapTarget = "${config.xdg.configHome}/input-remapper-2/xmodmap.json";
  profileSource = sourceRoot + "/razer/input-remapper-2/presets";
  profileTarget = "${config.xdg.configHome}/input-remapper-2/presets";
  syncProfiles = pkgs.writeShellApplication {
    name = "razer-profile-sync";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      force=false
      if [[ "''${1:-}" == "--force" ]]; then
        force=true
        shift
      fi
      if (($# != 0)); then
        printf 'usage: razer-profile-sync [--force]\n' >&2
        exit 2
      fi

      source_dir=${lib.escapeShellArg (toString profileSource)}
      target_dir=${lib.escapeShellArg profileTarget}
      config_source=${lib.escapeShellArg (toString configSource)}
      config_target=${lib.escapeShellArg configTarget}
      xmodmap_source=${lib.escapeShellArg (toString xmodmapSource)}
      xmodmap_target=${lib.escapeShellArg xmodmapTarget}
      copied=0
      preserved=0

      mkdir -p -- "$(dirname -- "$config_target")"
      if [[ "$force" == true || ! -e "$config_target" ]]; then
        install -m 0644 -- "$config_source" "$config_target"
        ((copied += 1))
      else
        ((preserved += 1))
      fi

      if [[ "$force" == true || ! -e "$xmodmap_target" ]]; then
        install -m 0644 -- "$xmodmap_source" "$xmodmap_target"
        ((copied += 1))
      else
        ((preserved += 1))
      fi

      while IFS= read -r -d "" source_file; do
        relative="''${source_file#"$source_dir"/}"
        target_file="$target_dir/$relative"
        mkdir -p -- "$(dirname -- "$target_file")"
        if [[ "$force" == true || ! -e "$target_file" ]]; then
          install -m 0644 -- "$source_file" "$target_file"
          ((copied += 1))
        else
          ((preserved += 1))
        fi
      done < <(find "$source_dir" -type f -name '*.json' -print0)

      printf 'Razer profiles: installed=%d preserved=%d target=%s\n' \
        "$copied" "$preserved" "$target_dir"
    '';
  };
in
{
  imports = [ ./core.nix ];

  config = lib.mkIf enabled {
    home.packages = [ syncProfiles ];

    # Seed real, user-writable files instead of immutable Home Manager links.
    # Input Remapper can then duplicate or edit them normally. Rebuilds only
    # add missing profiles; an explicit --force restores the tracked baseline.
    home.activation.installRazerProfiles = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${lib.getExe syncProfiles}
    '';
  };
}

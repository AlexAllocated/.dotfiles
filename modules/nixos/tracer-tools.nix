{
  config,
  lib,
  pkgs,
  self,
  toolPkgs ? pkgs,
  ...
}:
let
  cfg = config.dotfiles.tracerTools;
  source = toString cfg.source;
  codexPackage = import ../../packages/codex.nix { inherit lib pkgs; };
  mkTool =
    {
      name,
      script,
      runtimeInputs,
      environment ? "",
    }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = ''
        ${environment}
        exec ${pkgs.bash}/bin/bash ${source}/${script} "$@"
      '';
    };
  resumeTracer = mkTool {
    name = "resume-tracer";
    script = "scripts/nixos/resume-tracer.sh";
    runtimeInputs = [
      codexPackage
      pkgs.coreutils
      pkgs.git
      pkgs.tmux
    ];
  };
  tracerDiagnostics = mkTool {
    name = "tracer-diagnostics";
    script = "scripts/nixos/tracer-diagnostics.sh";
    runtimeInputs = with pkgs; [
      coreutils
      dmidecode
      ethtool
      gnugrep
      iproute2
      lm_sensors
      nvme-cli
      pciutils
      smartmontools
      systemd
      usbutils
      util-linux
    ];
  };
  rebootWindows = mkTool {
    name = "reboot-windows";
    script = "scripts/nixos/reboot-windows.sh";
    runtimeInputs = with pkgs; [
      coreutils
      efibootmgr
      jq
      gnused
      systemd
    ];
  };
  installTracer = mkTool {
    name = "install-tracer";
    script = "scripts/nixos/install-tracer.sh";
    environment = ''
      export TRACER_DOTFILES_SOURCE=${lib.escapeShellArg source}
    '';
    runtimeInputs = with pkgs; [
      btrfs-progs
      coreutils
      cryptsetup
      dosfstools
      findutils
      gawk
      git
      gnugrep
      gptfdisk
      jq
      nixos-install-tools
      parted
      rsync
      systemd
      util-linux
    ];
  };
in
{
  options.dotfiles.tracerTools = {
    enable = lib.mkEnableOption "Tracer installation, diagnostics, and conversation-resume tools";
    source = lib.mkOption {
      type = lib.types.path;
      default = self.outPath;
      description = "Immutable dotfiles source embedded in Tracer commands.";
    };
    rescueMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Include the destructive, confirmation-gated Tracer installer.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      resumeTracer
      tracerDiagnostics
      rebootWindows
    ]
    ++ lib.optional cfg.rescueMode installTracer;
  };
}

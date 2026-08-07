{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.githubActionsRunner;
  runnerNames = map (index: "${cfg.name}-${toString index}") (lib.range 1 cfg.instances);
  serviceNames = map (name: "github-runner-${name}") runnerNames;
  workDirFor = name: "/var/lib/github-runner-work/${name}";
  tokenDirectory = builtins.dirOf cfg.tokenFile;
  configureToken = pkgs.writeShellApplication {
    name = "configure-bumblebee-runner-token";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
    text = ''
      usage() {
        cat <<'EOF'
      Usage: configure-bumblebee-runner-token

      Securely prompts for the repository-scoped fine-grained GitHub PAT used
      to register Tracer's Bumblebee Actions runner. The token is stored only
      in the root-owned machine-local secret file and is never written to Nix.
      EOF
      }

      if (($#)); then
        case "$1" in
          -h | --help)
            (($# == 1)) || {
              printf '%s\n' '--help accepts no additional arguments.' >&2
              exit 2
            }
            usage
            exit 0
            ;;
          *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
        esac
      fi

      if ((EUID != 0)); then
        exec sudo -- "$0" "$@"
      fi

      printf '%s\n' 'Paste the fine-grained PAT for AlexAllocated/bumblebee.'
      printf '%s\n' 'It needs repository Administration: Read and write access.'
      read -r -s -p 'Token: ' token </dev/tty
      printf '\n'

      case "$token" in
        github_pat_* | ghp_*) ;;
        *)
          printf '%s\n' 'Expected a fine-grained or classic GitHub PAT; refusing to write it.' >&2
          exit 1
          ;;
      esac

      install -d -m 0700 ${lib.escapeShellArg tokenDirectory}
      temporary="$(mktemp --tmpdir github-runner-token.XXXXXX)"
      trap 'rm -f "$temporary"' EXIT
      printf '%s' "$token" >"$temporary"
      unset token
      install -m 0600 -o root -g root "$temporary" ${lib.escapeShellArg cfg.tokenFile}

      units=(
        ${lib.concatMapStringsSep "\n        " (name: lib.escapeShellArg "${name}.service") serviceNames}
      )
      systemctl reset-failed "''${units[@]}" || true
      systemctl restart "''${units[@]}"
      systemctl --no-pager --full status "''${units[@]}"
    '';
  };
in
{
  options.dotfiles.githubActionsRunner = {
    enable = lib.mkEnableOption "the repository-scoped Bumblebee GitHub Actions runner";
    name = lib.mkOption {
      type = lib.types.str;
      default = "bumblebee-tracer";
      description = "Stable prefix for GitHub Actions runner and NixOS service names.";
    };
    instances = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Number of concurrent repository jobs Tracer can accept.";
    };
    repository = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/AlexAllocated/bumblebee";
      description = "Private GitHub repository allowed to submit work to this runner.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/secrets/github-actions/bumblebee";
      description = "Root-owned machine-local fine-grained PAT file used for runner registration.";
    };
    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "bumblebee-build"
        "nixos"
        "tracer"
        "ryzen-9950x3d"
      ];
      description = "Custom labels used to route trusted Bumblebee jobs to this machine.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" (toString cfg.tokenFile);
        message = "The GitHub Actions runner token file must use an absolute path.";
      }
      {
        assertion = lib.elem "bumblebee-build" cfg.labels;
        message = "The Bumblebee runner must retain the bumblebee-build routing label.";
      }
    ];

    users.groups.github-runner-bumblebee = { };
    users.users.github-runner-bumblebee = {
      isSystemUser = true;
      group = "github-runner-bumblebee";
      extraGroups = [ "docker" ];
      home = "/var/lib/github-runner-work";
      createHome = false;
      description = "Repository-scoped Bumblebee GitHub Actions runner";
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/github-runner-work 0700 github-runner-bumblebee github-runner-bumblebee -"
      "d ${tokenDirectory} 0700 root root -"
    ]
    ++ map (
      name: "d ${workDirFor name} 0700 github-runner-bumblebee github-runner-bumblebee -"
    ) runnerNames;

    services.github-runners = lib.genAttrs runnerNames (name: {
      enable = true;
      url = cfg.repository;
      tokenFile = cfg.tokenFile;
      tokenType = "access";
      inherit name;
      extraLabels = cfg.labels;
      replace = true;
      ephemeral = false;
      user = "github-runner-bumblebee";
      group = "github-runner-bumblebee";
      workDir = workDirFor name;
      nodeRuntimes = [ "node24" ];
      extraPackages = with pkgs; [
        binutils
        bun
        cmake
        config.virtualisation.docker.package
        curl
        diffutils
        findutils
        gawk
        gcc
        git
        git-lfs
        gnugrep
        gnused
        jq
        kubectl
        libcxx
        nodejs_24
        openssl
        perl
        pkg-config
        rsync
        rustup
        unzip
        util-linux
        which
      ];
      extraEnvironment = {
        BUMBLEBEE_SELF_HOSTED_RUNNER = "1";
        DOCKER_BUILDKIT = "1";
        LD_LIBRARY_PATH = lib.makeLibraryPath [
          pkgs.libcxx
          pkgs.openssl
          pkgs.util-linux
        ];
        PKG_CONFIG_PATH = lib.makeSearchPath "lib/pkgconfig" [
          pkgs.openssl.dev
          pkgs.util-linux.dev
        ];
      };
      serviceOverrides = {
        # Docker's root-owned Unix socket cannot be used through the module's
        # default user namespace. Access remains restricted to this dedicated
        # account and is intentionally equivalent to host-root privileges.
        PrivateUsers = false;
        SupplementaryGroups = [ "docker" ];
      };
    });

    systemd.services = lib.genAttrs serviceNames (_: {
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      # Let the complete NixOS generation activate before the machine-local
      # secret exists. The setup helper writes it and starts the skipped unit.
      unitConfig.ConditionPathExists = cfg.tokenFile;
    });

    environment.systemPackages = [ configureToken ];
  };
}

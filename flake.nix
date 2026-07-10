{
  description = "Alex's Nix-powered dotfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      nixos-wsl,
      nix-darwin,
      ...
    }:
    let
      linuxUser = "alex";
      darwinUser = "alexford";
      fullName = "Alex";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      mkToolPkgs =
        system:
        import nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (mkPkgs system));
      forLinuxSystems =
        f: nixpkgs.lib.genAttrs linuxSystems (system: f (mkPkgs system) (mkToolPkgs system));

      mkQualityCheck =
        pkgs:
        pkgs.runCommand "dotfiles-quality"
          {
            nativeBuildInputs = with pkgs; [
              bash
              git
              lua
              nixfmt
              prettier
              python3
              rsync
              shellcheck
              shfmt
              stylua
            ];
          }
          ''
              cp -R ${self} source
              chmod -R u+w source
              cd source
              find . -name '*.nix' -print0 | xargs -0 nixfmt --check
            shellcheck scripts/dotctl scripts/lib/*.sh scripts/commands/*.sh scripts/profiles/*.sh dot-bootstrap tests/*.bash
            bash -n scripts/dotctl scripts/lib/*.sh scripts/commands/*.sh scripts/profiles/*.sh dot-bootstrap tests/*.bash
            shfmt -d -i 0 -ci scripts/dotctl scripts/lib/*.sh scripts/commands/*.sh scripts/profiles/*.sh dot-bootstrap tests/*.bash
            bash tests/dotctl.bash
            stylua --check nvim .wezterm.lua wezterm
            find nvim wezterm -name '*.lua' -print0 | xargs -0 -n1 luac -p
            python3 -m py_compile scripts/codex/*.py
            prettier --check README.md AGENTS.md docs .github
              touch $out
          '';

      mkModuleApiCheck =
        pkgs: system:
        let
          checkModule =
            name: module:
            let
              evaluated = home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                extraSpecialArgs = {
                  profile = "generic";
                  toolPkgs = mkToolPkgs system;
                };
                modules = [
                  module
                  {
                    home.username = "dotfiles-test";
                    home.homeDirectory = "/home/dotfiles-test";
                    home.stateVersion = "26.05";
                  }
                ];
              };
            in
            "${name}:${builtins.unsafeDiscardStringContext evaluated.activationPackage.drvPath}";
          evaluatedModules = nixpkgs.lib.mapAttrsToList checkModule homeModules;
        in
        pkgs.writeText "home-module-api" (nixpkgs.lib.concatStringsSep "\n" evaluatedModules);

      mkDarwinProfileCheck =
        pkgs: system:
        let
          homeProfile = mkHome {
            inherit system;
            user = "dotfiles-test";
            profile = "macos";
            homeDirectory = "/Users/dotfiles-test";
          };
          darwinProfile = mkDarwin system "darwin-macos" "dotfiles-test";
          outputs = [
            "home:${builtins.unsafeDiscardStringContext homeProfile.activationPackage.drvPath}"
            "darwin:${builtins.unsafeDiscardStringContext darwinProfile.system.drvPath}"
          ];
        in
        pkgs.writeText "darwin-profile-api" (nixpkgs.lib.concatStringsSep "\n" outputs);

      homeModules = {
        core = ./modules/home/core.nix;
        foundation = ./modules/home/foundation.nix;
        development = ./modules/home/development.nix;
        shell = ./modules/home/shell.nix;
        git = ./modules/home/git.nix;
        nvim = ./modules/home/nvim.nix;
        codex = ./modules/home/codex.nix;
        cloud = ./modules/home/cloud.nix;
        terminal = ./modules/home/terminal.nix;
        windows = ./modules/home/windows.nix;
        default = ./modules/home/default.nix;
      };

      mkDotctlApp =
        pkgs:
        let
          dotctl = pkgs.writeShellApplication {
            name = "dotctl";
            text = ''
              exec ${self}/scripts/dotctl "$@"
            '';
          };
        in
        {
          type = "app";
          program = "${dotctl}/bin/dotctl";
          meta.description = "Run dotctl from the dotfiles flake.";
        };

      mkSpecialArgs = system: user: {
        inherit
          inputs
          self
          user
          ;
        toolPkgs = mkToolPkgs system;
      };

      mkHome =
        {
          system,
          user,
          profile,
          homeDirectory,
        }:
        home-manager.lib.homeManagerConfiguration {
          pkgs = mkPkgs system;
          extraSpecialArgs = (mkSpecialArgs system user) // {
            inherit profile;
          };
          modules = [
            ./modules/home/default.nix
            {
              home.username = user;
              home.homeDirectory = homeDirectory;
              home.stateVersion = "26.05";
              dotfiles = {
                inherit profile;
              };
            }
          ];
        };

      mkDarwin =
        system: profile: user:
        nix-darwin.lib.darwinSystem {
          inherit system;
          specialArgs = (mkSpecialArgs system user) // {
            inherit profile;
          };
          modules = [
            home-manager.darwinModules.home-manager
            ./modules/darwin/default.nix
          ];
        };

      linuxHomeConfiguration = mkHome {
        user = linuxUser;
        system = "x86_64-linux";
        profile = "linux";
        homeDirectory = "/home/${linuxUser}";
      };
      macosHomeConfiguration = mkHome {
        user = darwinUser;
        system = "aarch64-darwin";
        profile = "macos";
        homeDirectory = "/Users/${darwinUser}";
      };
      macosIntelHomeConfiguration = mkHome {
        user = darwinUser;
        system = "x86_64-darwin";
        profile = "macos-intel";
        homeDirectory = "/Users/${darwinUser}";
      };
    in
    {
      nixosConfigurations.wsl = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = (mkSpecialArgs "x86_64-linux" linuxUser) // {
          profile = "nixos-wsl";
        };
        modules = [
          nixos-wsl.nixosModules.default
          home-manager.nixosModules.home-manager
          ./modules/nixos/wsl.nix
          {
            dotfiles.wsl = {
              user = linuxUser;
              userDescription = fullName;
            };
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-backup";
            home-manager.extraSpecialArgs = (mkSpecialArgs "x86_64-linux" linuxUser) // {
              profile = "nixos-wsl";
            };
            home-manager.users.${linuxUser} = {
              imports = [ ./modules/home/default.nix ];
              home.username = linuxUser;
              home.homeDirectory = "/home/${linuxUser}";
              home.stateVersion = "26.05";
              dotfiles = {
                profile = "nixos-wsl";
                codex.manageConfig = false;
              };
            };
          }
        ];
      };

      nixosConfigurations.nixos-wsl = self.nixosConfigurations.wsl;

      homeConfigurations = {
        linux = linuxHomeConfiguration;
        macos-arm64 = macosHomeConfiguration;
        macos-x86_64 = macosIntelHomeConfiguration;
        macos = self.homeConfigurations.macos-arm64;
        macos-intel = self.homeConfigurations.macos-x86_64;
      };

      darwinConfigurations = {
        macos-arm64 = mkDarwin "aarch64-darwin" "darwin-macos" darwinUser;
        macos-x86_64 = mkDarwin "x86_64-darwin" "darwin-macos-intel" darwinUser;
        darwin-macos = self.darwinConfigurations.macos-arm64;
        darwin-macos-intel = self.darwinConfigurations.macos-x86_64;
      };

      inherit homeModules;
      nixosModules.wsl = ./modules/nixos/wsl.nix;

      packages = forLinuxSystems (
        pkgs: toolPkgs:
        import ./modules/docker/images.nix {
          inherit
            pkgs
            toolPkgs
            ;
          user = "dev";
          source = self.outPath;
        }
      );

      apps = forAllSystems (pkgs: {
        dotctl = mkDotctlApp pkgs;
        default = mkDotctlApp pkgs;
      });

      formatter = forAllSystems (
        pkgs:
        pkgs.writeShellApplication {
          name = "dotfiles-format";
          runtimeInputs = with pkgs; [
            nixfmt
            prettier
            shfmt
            stylua
            treefmt
          ];
          text = ''
            exec treefmt "$@"
          '';
        }
      );

      checks = forAllSystems (
        pkgs:
        {
          quality = mkQualityCheck pkgs;
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          home-module-api = mkModuleApiCheck pkgs pkgs.stdenv.hostPlatform.system;
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          profile-api = mkDarwinProfileCheck pkgs pkgs.stdenv.hostPlatform.system;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            nixfmt
            prettier
            shellcheck
            shfmt
            stylua
            treefmt
          ];
        };
      });

      lib = {
        inherit homeModules;
        toolsetsFor =
          system:
          import ./lib/toolsets.nix {
            inherit (nixpkgs) lib;
            pkgs = mkPkgs system;
            toolPkgs = mkToolPkgs system;
          };
      };
    };
}

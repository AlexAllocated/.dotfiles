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
      user = "alex";
      fullName = "Alex";
      userEmail = "Alex@HiveTech.ai";
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      linuxSystems = [ "x86_64-linux" ];

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

      homeModules = {
        core = ./modules/home/core.nix;
        packages = ./modules/home/packages.nix;
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
          fullName
          userEmail
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
              dotfiles = {
                inherit
                  fullName
                  profile
                  userEmail
                  ;
                userName = user;
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
        inherit user;
        system = "x86_64-linux";
        profile = "linux";
        homeDirectory = "/home/${user}";
      };
    in
    {
      nixosConfigurations.nixos-wsl = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = (mkSpecialArgs "x86_64-linux" user) // {
          profile = "nixos-wsl";
        };
        modules = [
          nixos-wsl.nixosModules.default
          home-manager.nixosModules.home-manager
          ./modules/nixos/wsl.nix
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-backup";
            home-manager.extraSpecialArgs = (mkSpecialArgs "x86_64-linux" user) // {
              profile = "nixos-wsl";
            };
            home-manager.users.${user} = {
              imports = [ ./modules/home/default.nix ];
              home.username = user;
              home.homeDirectory = "/home/${user}";
              dotfiles = {
                inherit fullName userEmail;
                profile = "nixos-wsl";
                userName = user;
              };
            };
          }
        ];
      };

      homeConfigurations.linux = linuxHomeConfiguration;

      darwinConfigurations = {
        macos = mkDarwin "aarch64-darwin" "macos" user;
        macos-intel = mkDarwin "x86_64-darwin" "macos-intel" user;
      };

      inherit homeModules;

      packages = forLinuxSystems (
        pkgs: toolPkgs:
        import ./modules/docker/images.nix {
          inherit
            pkgs
            toolPkgs
            user
            fullName
            userEmail
            ;
          source = self.outPath;
        }
      );

      apps = forAllSystems (pkgs: {
        dotctl = mkDotctlApp pkgs;
        default = mkDotctlApp pkgs;
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}

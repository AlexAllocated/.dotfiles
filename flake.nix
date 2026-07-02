{
  description = "Chev's Nix-powered dotfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

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
      home-manager,
      nixos-wsl,
      nix-darwin,
      ...
    }:
    let
      user = "chev";
      fullName = "Alex";
      userEmail = "Alex@HiveTech.ai";

      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      baseSpecialArgs = {
        inherit
          inputs
          self
          user
          fullName
          userEmail
          ;
      };

      mkHome =
        {
          system,
          profile,
          homeDirectory,
        }:
        home-manager.lib.homeManagerConfiguration {
          pkgs = mkPkgs system;
          extraSpecialArgs = baseSpecialArgs // {
            inherit profile;
          };
          modules = [
            ./modules/home/default.nix
            {
              home.username = user;
              home.homeDirectory = homeDirectory;
              dotfiles.profile = profile;
            }
          ];
        };

      mkDarwin =
        system:
        nix-darwin.lib.darwinSystem {
          inherit system;
          specialArgs = baseSpecialArgs // {
            profile = "macos";
          };
          modules = [
            home-manager.darwinModules.home-manager
            ./modules/darwin/default.nix
          ];
        };
    in
    {
      nixosConfigurations.nixos-wsl = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = baseSpecialArgs // {
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
            home-manager.extraSpecialArgs = baseSpecialArgs // {
              profile = "nixos-wsl";
            };
            home-manager.users.${user} = {
              imports = [ ./modules/home/default.nix ];
              home.username = user;
              home.homeDirectory = "/home/${user}";
              dotfiles.profile = "nixos-wsl";
            };
          }
        ];
      };

      homeConfigurations = {
        "${user}@wsl-ubuntu" = mkHome {
          system = "x86_64-linux";
          profile = "wsl-ubuntu";
          homeDirectory = "/home/${user}";
        };

        "${user}@ubuntu" = mkHome {
          system = "x86_64-linux";
          profile = "ubuntu";
          homeDirectory = "/home/${user}";
        };

        "${user}@generic-linux" = mkHome {
          system = "x86_64-linux";
          profile = "generic-linux";
          homeDirectory = "/home/${user}";
        };
      };

      darwinConfigurations = {
        "${user}-macos" = mkDarwin "aarch64-darwin";
        "${user}-macos-intel" = mkDarwin "x86_64-darwin";
      };

      formatter.x86_64-linux = (mkPkgs "x86_64-linux").nixfmt;
      formatter.aarch64-darwin = (mkPkgs "aarch64-darwin").nixfmt;
      formatter.x86_64-darwin = (mkPkgs "x86_64-darwin").nixfmt;
    };
}

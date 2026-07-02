{
  description = "Alex's Nix-powered dotfiles";

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
      user = "alex";
      fullName = "Alex";
      userEmail = "Alex@HiveTech.ai";

      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      mkSpecialArgs =
        user:
        {
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
          user,
          profile,
          homeDirectory,
        }:
        home-manager.lib.homeManagerConfiguration {
          pkgs = mkPkgs system;
          extraSpecialArgs = (mkSpecialArgs user) // {
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
        system: user:
        nix-darwin.lib.darwinSystem {
          inherit system;
          specialArgs = (mkSpecialArgs user) // {
            profile = "macos";
          };
          modules = [
            home-manager.darwinModules.home-manager
            ./modules/darwin/default.nix
          ];
        };

      mkLinuxHomeConfigurations =
        user:
        {
          "${user}@generic-linux" = mkHome {
            inherit user;
            system = "x86_64-linux";
            profile = "generic-linux";
            homeDirectory = "/home/${user}";
          };
        };

      mkDarwinConfigurations =
        user:
        {
          "${user}-macos" = mkDarwin "aarch64-darwin" user;
          "${user}-macos-intel" = mkDarwin "x86_64-darwin" user;
        };
    in
    {
      nixosConfigurations.nixos-wsl = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = (mkSpecialArgs user) // {
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
            home-manager.extraSpecialArgs = (mkSpecialArgs user) // {
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

      homeConfigurations = mkLinuxHomeConfigurations user;

      darwinConfigurations = mkDarwinConfigurations user;

      formatter.x86_64-linux = (mkPkgs "x86_64-linux").nixfmt;
      formatter.aarch64-darwin = (mkPkgs "aarch64-darwin").nixfmt;
      formatter.x86_64-darwin = (mkPkgs "x86_64-darwin").nixfmt;
    };
}

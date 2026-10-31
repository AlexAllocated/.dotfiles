{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./core.nix ];
  options.dotfiles.unrealEngine.enable = lib.mkEnableOption "native Unreal Engine Linux development";
  config = lib.mkIf config.dotfiles.unrealEngine.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "Epic's precompiled Unreal Engine Linux editor requires x86_64-linux.";
      }
    ];
    home.packages = [ (pkgs.callPackage ../../packages/unreal-engine.nix { }) ];
    xdg.desktopEntries.unreal-engine = {
      name = "Unreal Engine";
      genericName = "Game Engine Editor";
      exec = "unreal-engine %f";
      terminal = false;
      categories = [
        "Development"
        "Graphics"
      ];
      mimeType = [ "application/x-unreal-project" ];
    };
    xdg.dataFile."mime/packages/unreal-engine.xml".text = ''
      <mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
        <mime-type type="application/x-unreal-project">
          <comment>Unreal Engine project</comment>
          <glob pattern="*.uproject"/>
        </mime-type>
      </mime-info>
    '';
  };
}

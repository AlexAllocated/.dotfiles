{ lib, pkgs }:
let
  registry = pkgs.runCommand "unreal-engine-storage-registry" { } ''
    mkdir -p "$out/catalog" "$out/scripts/dotfiles"
    cp ${../catalog/policy.json} "$out/catalog/policy.json"
    cp ${../scripts/dotfiles/core.py} "$out/scripts/dotfiles/core.py"
    cp ${../scripts/dotfiles/storage.py} "$out/scripts/dotfiles/storage.py"
  '';
  runtime = pkgs.buildFHSEnv {
    name = "unreal-engine-runtime";
    targetPkgs =
      p: with p; [
        alsa-lib
        at-spi2-core
        bash
        cairo
        coreutils
        dbus
        expat
        fontconfig
        freetype
        glib
        gtk3
        icu
        libdrm
        libgbm
        libglvnd
        libpulseaudio
        libx11
        libxcb
        libxcomposite
        libxcursor
        libxdamage
        libxext
        libxfixes
        libxi
        libxinerama
        libxkbcommon
        libxrandr
        libxrender
        libxscrnsaver
        libxtst
        nss
        nspr
        openssl
        pango
        stdenv.cc.cc.lib
        udev
        vulkan-loader
        wayland
        xdg-utils
        xdg-user-dirs
        zlib
      ];
    multiArch = false;
    runScript = "bash";
  };
in
pkgs.writeShellApplication {
  name = "unreal-engine";
  runtimeInputs = [
    pkgs.python3
    pkgs.unzip
  ];
  text = ''
    exec python3 ${../scripts/unreal/engine.py} --runtime ${lib.getExe runtime} --registry-root ${registry} "$@"
  '';
  meta = {
    description = "Native Unreal Engine Linux installer and FHS launcher";
    homepage = "https://www.unrealengine.com/linux";
    platforms = [ "x86_64-linux" ];
    mainProgram = "unreal-engine";
  };
}

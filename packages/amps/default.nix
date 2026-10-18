{
  pkgs,
  lib ? pkgs.lib,
}:
let
  source = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: type:
      !(builtins.elem (baseNameOf path) [
        "target"
        "node_modules"
        "web"
        "__pycache__"
      ]);
  };
  frontend = pkgs.buildNpmPackage {
    pname = "amps-frontend";
    version = "0.1.0";
    src = source + "/ui";
    npmDepsHash = "sha256-sOka1K7rruPfkazRHKuJr/jJBb19/4Xf9/9eKyH3u/E=";
    installPhase = ''
      cp -r web "$out"
    '';
  };
  engine = pkgs.rustPlatform.buildRustPackage {
    pname = "amps";
    version = "0.1.0";
    src = source;
    AMPS_TIMEOUT_BIN = lib.getExe' pkgs.coreutils "timeout";
    cargoLock = {
      lockFile = ./Cargo.lock;
    };
  };
  ui = pkgs.rustPlatform.buildRustPackage {
    pname = "amps-ui";
    version = "0.1.0";
    src = source;
    AMPS_TIMEOUT_BIN = lib.getExe' pkgs.coreutils "timeout";
    cargoLock = {
      lockFile = ./ui/src-tauri/Cargo.lock;
    };
    cargoRoot = "ui/src-tauri";
    buildAndTestSubdir = "ui/src-tauri";
    nativeBuildInputs = [
      pkgs.pkg-config
      pkgs.wrapGAppsHook3
      pkgs.librsvg
    ];
    buildInputs = [
      pkgs.webkitgtk_4_1
      pkgs.gtk3
      pkgs.openssl
      pkgs.libayatana-appindicator
      pkgs.libxkbcommon
      pkgs.gst_all_1.gst-plugins-base
      pkgs.gst_all_1.gst-plugins-good
      pkgs.gst_all_1.gst-libav
    ];
    preBuild = ''
      cp -r ${frontend} ui/web
      rsvg-convert -w 256 -h 256 ui/src-tauri/icons/amps.svg -o ui/src-tauri/icons/icon.png
    '';
    postInstall = ''
      install -Dm644 ui/src-tauri/icons/amps.svg "$out/share/icons/hicolor/scalable/apps/amps.svg"
    '';
  };
in
{
  inherit engine ui frontend;
}

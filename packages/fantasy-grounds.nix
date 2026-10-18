{
  lib,
  pkgs,
}:
let
  # The vendor URL rolls; the hash pins the native Linux bootstrap installer.
  installer = pkgs.fetchurl {
    name = "FGUWebInstall-2025-11-11.bin";
    url = "https://www.fantasygrounds.com/filelibrary/FGUWebInstall.bin";
    hash = "sha256-rfNaVxVJJmxxghEDqL5Jn4EF5dxw6mu7LHSg4JbRCXA=";
  };
  bootstrap = pkgs.stdenvNoCC.mkDerivation {
    pname = "fantasy-grounds-bootstrap";
    version = "2025-11-11";
    src = installer;
    unpackPhase = ''
      runHook preUnpack
      archive_line=$(awk '/^__ARCHIVE_BELOW__$/ {print NR + 1; exit}' "$src")
      test -n "$archive_line"
      tail -n +"$archive_line" "$src" | tar xz
      mkdir bootstrap
      tar xf files.tar -C bootstrap
      runHook postUnpack
    '';
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R bootstrap/. "$out/"
      head -n "$((archive_line - 1))" "$src" > "$out/installer-eula.txt"
      runHook postInstall
    '';
  };
  launcher = pkgs.writeShellApplication {
    name = "fantasy-grounds-launch";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      if [[ "''${1:-}" == --help ]]; then
        printf 'Usage: fantasy-grounds [--update | --install-only] [client arguments...]\n'
        exit 0
      fi
      # Match upstream's installation path so its own updater and settings
      # work. Binaries must be writable because the vendor updates them in place.
      app_dir="$HOME/.smiteworks/fantasygrounds"
      mkdir -p "$app_dir"
      exec 9>"$app_dir/.bootstrap.lock"
      flock 9
      if [[ ! -e "$app_dir/FantasyGroundsUpdater" ]]; then
        cp -R --no-clobber ${bootstrap}/. "$app_dir/"
        chmod -R u+w "$app_dir"
      fi
      flock -u 9
      exec 9>&-
      if [[ "''${1:-}" == --install-only ]]; then
        exit 0
      fi
      cd "$app_dir"
      if [[ "''${1:-}" == --update ]]; then
        shift
        exec ./FantasyGroundsUpdater "$@"
      fi
      if [[ ! -x ./FantasyGrounds.x86_64 ]]; then
        exec ./FantasyGroundsUpdater "$@"
      fi
      exec ./FantasyGrounds.x86_64 "$@"
    '';
  };
in
pkgs.buildFHSEnv {
  pname = "fantasy-grounds";
  version = "2025-11-11";
  runScript = lib.getExe launcher;
  # Both the pinned bootstrap and subsequently downloaded native Unity builds
  # run in the same FHS environment, including updater-spawned child processes.
  targetPkgs =
    p: with p; [
      alsa-lib
      bash
      cairo
      corefonts
      dbus
      fontconfig
      freetype
      glib
      gtk3
      libglvnd
      libpulseaudio
      libx11
      libxcursor
      libxext
      libxfixes
      libxi
      libxkbcommon
      libxrandr
      libxrender
      openssl
      pango
      stdenv.cc.cc.lib
      udev
      vulkan-loader
      wayland
      xdg-utils
      zlib
    ];
  multiArch = false;
  passthru = { inherit bootstrap; };
  meta = {
    description = "Fantasy Grounds VTT native Linux installer, updater, and launcher";
    homepage = "https://www.fantasygrounds.com/";
    license = lib.licenses.unfree;
    mainProgram = "fantasy-grounds";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

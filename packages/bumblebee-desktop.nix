{
  lib,
  appimageTools,
  fetchurl,
}:
let
  pname = "bumblebee-desktop";
  version = "0.1.2-preview.3";
  src = fetchurl {
    url = "https://github.com/AlexAllocated/bumblebee-desktop/releases/download/v${version}/Bumblebee_0.1.2_amd64.AppImage";
    hash = "sha256-385OGgVlkkKZ3sBvt32yj3L3dl8s31pXccCbqPS+RGk=";
  };
  contents = appimageTools.extractType2 { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;
  extraPkgs = p: [
    p.libsecret
    p.alsa-lib
    p.libayatana-appindicator
    p.libuuid
    p.llvmPackages.libcxx
  ];
  # Match the upstream wrapper: host GVfs modules must not load into the
  # AppImage's bundled GLib. The AppImage configures its own module directory.
  profile = ''
    unset GIO_MODULE_DIR GIO_EXTRA_MODULES
  '';
  extraInstallCommands = ''
    install -Dm444 ${contents}/usr/share/applications/Bumblebee.desktop $out/share/applications/bumblebee-desktop.desktop
    install -Dm444 ${contents}/usr/share/icons/hicolor/128x128/apps/bumblebee-desktop.png $out/share/icons/hicolor/128x128/apps/bumblebee-desktop.png
  '';
  meta = {
    description = "Bumblebee streaming companion";
    homepage = "https://github.com/AlexAllocated/bumblebee-desktop";
    # Project code is MIT; packaged Speech SDK and artwork have separate terms.
    license = [
      lib.licenses.mit
      lib.licenses.unfreeRedistributable
    ];
    mainProgram = "bumblebee-desktop";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

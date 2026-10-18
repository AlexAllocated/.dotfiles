{
  lib,
  appimageTools,
  fetchurl,
}:
let
  pname = "curseforge";
  version = "1.321.1-39714";
  src = fetchurl {
    # Upstream exposes a rolling URL; the hash pins the reviewed release.
    name = "CurseForge-${version}.AppImage";
    url = "https://curseforge.overwolf.com/downloads/curseforge-latest-linux.AppImage";
    hash = "sha256-4DQZNlrJGY1gGAyqB74+vhhI9lCDPAEQrayhSX5G0Uc=";
  };
  contents = appimageTools.extractType2 { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;
  extraInstallCommands = ''
    install -Dm444 ${contents}/curseforge.desktop $out/share/applications/curseforge.desktop
    substituteInPlace $out/share/applications/curseforge.desktop \
      --replace-fail 'Exec=AppRun --no-sandbox %U' 'Exec=curseforge %U'
    install -Dm444 ${contents}/curseforge.png $out/share/icons/hicolor/256x256/apps/curseforge.png
  '';
  meta = {
    description = "Official CurseForge addon and mod manager";
    homepage = "https://www.curseforge.com/download/app";
    license = lib.licenses.unfree;
    mainProgram = "curseforge";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

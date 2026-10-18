{
  lib,
  appimageTools,
  fetchurl,
}:
let
  pname = "curseforge";
  version = "1.324.0-41180";
  src = fetchurl {
    # Keep the reviewed release fetchable after upstream advances latest-linux.yml.
    name = "CurseForge-${version}.AppImage";
    url = "https://curseforge.overwolf.com/electron/linux/CurseForge-${version}.AppImage";
    hash = "sha256-co4Exw7Nm57m9m1oyFQ9hypnulZVFHfO6iopp3pWPD8=";
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

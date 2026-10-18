{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
}:
stdenv.mkDerivation {
  pname = "amps-nvidia-afx-linux";
  version = "2.1.0-rtx50";
  src = fetchurl {
    url = "https://arzvak.com/downloads/linux-broadcast/v0.2.0/linux-broadcast_0.2.0_rtx50_amd64.deb";
    hash = "sha256-lwPuWW1rqxR+XgwJt4veIihPp0+GAtotm6pAluZMy5A=";
  };
  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
  ];
  buildInputs = [ stdenv.cc.cc.lib ];
  autoPatchelfIgnoreMissingDeps = [ "libcuda.so.1" ];
  unpackPhase = ''
    dpkg-deb -x "$src" unpacked
  '';
  installPhase = ''
    mkdir -p "$out/lib" "$out/share/licenses"
    cp -a unpacked/usr/lib/linux-broadcast/. "$out/lib/"
    cp -a unpacked/usr/share/licenses/linux-broadcast "$out/share/licenses/"
  '';
  meta = {
    description = "Native NVIDIA AFX runtime and PipeWire LADSPA adapter for Blackwell";
    homepage = "https://github.com/arzvaak/linux-broadcast";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
  };
}

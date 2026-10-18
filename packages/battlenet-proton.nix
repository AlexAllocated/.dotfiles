{
  lib,
  stdenvNoCC,
  requireFile,
  callPackage,
  pkgsi686Linux,
  xorg-server,
}:
let
  pin = builtins.fromJSON (builtins.readFile ../pins/battlenet-proton.json);
  randR = callPackage ./libxrandr-hotplug.nix { };
  randR32 = pkgsi686Linux.callPackage ./libxrandr-hotplug.nix { inherit xorg-server; };
in
stdenvNoCC.mkDerivation {
  pname = "battlenet-proton";
  inherit (pin) version;
  src = requireFile {
    name = pin.archive;
    inherit (pin) sha256;
    message = ''
      			Stage the installed ${pin.version} Steam runtime with:
      			python3 scripts/gaming/stage-battlenet-proton.py
      			This imports a verified runtime snapshot; it never copies the game prefix.
      		'';
  };
  unpackPhase = ''
    		mkdir runtime
    		tar -xf "$src" -C runtime
    		cd runtime
    	'';
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;
  dontPatchShebangs = true;
  installPhase = ''
    		test "$(cat version)" = ${lib.escapeShellArg pin.upstreamVersion}
    		cp -a . "$out"
    		chmod -R u+w "$out"
    		# Steam already restored these files. Never rerun Steam's in-place
    		# materialization against an immutable Nix store path.
    		rm -f "$out/steampipe_fixups.json" "$out/dist.lock"
    		ln -sf ${randR}/lib/libXrandr.so.2 "$out/files/lib/x86_64-linux-gnu/libXrandr.so.2"
    		ln -sf ${randR32}/lib/libXrandr.so.2 "$out/files/lib/i386-linux-gnu/libXrandr.so.2"
    	'';
  passthru = { inherit randR randR32; };
  meta = {
    description = "Verified Battle.net Proton snapshot with scoped XRandR hotplug handling";
    license = with lib.licenses; [
      bsd3
      lgpl21Plus
      zlib
    ];
    platforms = [ "x86_64-linux" ];
  };
}

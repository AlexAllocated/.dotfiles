{ lib, pkgs }:
let
  pin = builtins.fromJSON (builtins.readFile ../pins/codex.json);
  system = pkgs.stdenv.hostPlatform.system;
  asset = pin.assets.${system} or (throw "The official Codex package is not pinned for ${system}");
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "codex";
  inherit (pin) version;

  src = pkgs.fetchurl {
    inherit (asset) url sha256;
  };

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -R bin codex-path codex-resources codex-package.json "$out/"
    test -x "$out/bin/codex"

    runHook postInstall
  '';

  meta = {
    description = "OpenAI Codex command-line coding agent";
    homepage = "https://learn.chatgpt.com/docs/codex/cli";
    license = lib.licenses.asl20;
    mainProgram = "codex";
    platforms = builtins.attrNames pin.assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

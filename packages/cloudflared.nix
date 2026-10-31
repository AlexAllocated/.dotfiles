{
  lib,
  stdenvNoCC,
  fetchurl,
}:

# Keep the tunnel's certificate trust update independent of the host nixpkgs
# and the private resume application's Node/Python runtime.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "cloudflared";
  version = "2026.10.3";

  src = fetchurl {
    url = "https://github.com/cloudflare/cloudflared/releases/download/${finalAttrs.version}/cloudflared-linux-amd64";
    hash = "sha256-BTuAsKIwMaA4/b88Bz9Z+CuPHxUqpnlx1zg/+vwNurA=";
  };

  dontUnpack = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/cloudflared"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/cloudflared" --version | grep -F "cloudflared version ${finalAttrs.version} "
    runHook postInstallCheck
  '';

  meta = {
    description = "Cloudflare Tunnel connector with updated certificate trust";
    homepage = "https://github.com/cloudflare/cloudflared";
    license = lib.licenses.asl20;
    mainProgram = "cloudflared";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})

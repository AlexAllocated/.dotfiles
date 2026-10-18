{
  davinci-resolve,
  buildFHSEnv,
  lib,
  requireFile,
  stdenv,
}:
let
  pin = builtins.fromJSON (builtins.readFile ../pins/davinci-resolve.json);
  archive = "DaVinci_Resolve_${pin.version}_Linux.zip";
in
# Keep Nixpkgs' FHS environment, desktop launchers, and driver integration.
# Override its inner application derivation so every wrapper uses the update.
davinci-resolve.override {
  buildFHSEnv =
    args:
    buildFHSEnv (
      args
      // {
        targetPkgs =
          pkgs:
          lib.filter (package: (package.pname or "") != "libxcrypt") (args.targetPkgs pkgs)
          ++ [ pkgs.libxcrypt-legacy ];
      }
    );
  stdenv = stdenv // {
    mkDerivation =
      args:
      (stdenv.mkDerivation args).overrideAttrs (old: {
        version = pin.version;
        src = requireFile {
          name = archive;
          sha256 = pin.sha256;
          message = ''
            Download the free Linux ${pin.version} release from Blackmagic Design:
            https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion
            Then run: nix-store --add-fixed sha256 /path/to/${archive}
          '';
        };
        installPhase = lib.replaceStrings [ old.version ] [ pin.version ] old.installPhase;
        # Resolve 21 checks this new support directory even for ordinary
        # projects. Create it before the application enters the read-only store.
        postInstall = (old.postInstall or "") + ''
          mkdir -p "$out/Immersive/Canon/STMap"
        '';
        # Resolve 21 removed bundled OpenSSL 1.1. libcrypt is provided by
        # Nixpkgs' libxcrypt-legacy in the FHS environment, not by libcrypto.
        postFixup =
          lib.replaceStrings [ "ln -s $out/libs/libcrypto.so.1.1 $out/libs/libcrypt.so.1" ] [ "" ]
            old.postFixup;
      });
  };
}

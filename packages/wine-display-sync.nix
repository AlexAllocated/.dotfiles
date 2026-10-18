{
  lib,
  stdenv,
  windows,
}:
stdenv.mkDerivation {
  pname = "wine-display-sync";
  version = "1";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../scripts/gaming/wine-display-sync.c
      ../scripts/gaming/wine-display-probe.c
      ../tests/wine-display-sync.c
      ../tests/wine-modeset-policy.c
    ];
  };
  buildInputs = [ windows.mcfgthreads ];
  buildPhase = ''
    runHook preBuild
    $CC -std=c11 -Wall -Wextra -Werror -O2 -static \
      scripts/gaming/wine-display-sync.c -o wine-display-sync.exe -luser32 -ladvapi32
    $CC -std=c11 -Wall -Wextra -Werror -O2 -static \
      tests/wine-display-sync.c -o wine-display-sync-test.exe -luser32 -ladvapi32
    $CC -std=c11 -Wall -Wextra -Werror -O2 -static \
      tests/wine-modeset-policy.c -o wine-modeset-policy-test.exe -luser32 -lshcore
    $CC -std=c11 -Wall -Wextra -Werror -O2 -static \
      scripts/gaming/wine-display-probe.c -o wine-display-probe.exe -luser32 -lshcore
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 wine-display-sync.exe "$out/bin/wine-display-sync.exe"
    install -Dm755 wine-display-sync-test.exe "$out/libexec/wine-display-sync-test.exe"
    install -Dm755 wine-modeset-policy-test.exe "$out/libexec/wine-modeset-policy-test.exe"
    install -Dm755 wine-display-probe.exe "$out/bin/wine-display-probe.exe"
    runHook postInstall
  '';
}

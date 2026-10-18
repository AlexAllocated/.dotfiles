{ iloader, rustPlatform }:
iloader.overrideAttrs (old: {
  cargoDeps = rustPlatform.importCargoLock {
    lockFile = old.src + "/src-tauri/Cargo.lock";
    outputHashes = builtins.fromJSON (builtins.readFile ../pins/iloader-cargo.json);
  };
})

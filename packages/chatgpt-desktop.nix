{ lib, pkgs }:
let
  pin = builtins.fromJSON (builtins.readFile ../pins/chatgpt-desktop.json);
  system = pkgs.stdenv.hostPlatform.system;
  asset = pin.assets.${system};
  nodeArch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x64";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "chatgpt-desktop";
  inherit (pin) version;

  src = pkgs.fetchurl { inherit (asset) url sha256; };
  nativeBuildInputs = with pkgs; [
    asar
    autoPatchelfHook
    dpkg
    makeWrapper
    wrapGAppsHook3
  ];
  buildInputs = with pkgs; [
    alsa-lib
    at-spi2-core
    cairo
    cups
    dbus
    expat
    glib
    gtk3
    libdrm
    libgbm
    libusb1
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    nspr
    nss
    openssl
    pango
    stdenv.cc.cc.lib
    systemd
    tpm2-tss
  ];
  runtimeDependencies = map lib.getLib (
    with pkgs;
    [
      libglvnd
      libnotify
      libpulseaudio
      vulkan-loader
      wayland
    ]
  );

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';
  dontConfigure = true;
  dontBuild = true;
  dontWrapGApps = true;
  # Preserve the vendor's bundled Chromium, agent, and native Node modules.
  dontStrip = true;

  postPatch = ''
    asar extract usr/lib/chatgpt/resources/app.asar app-source
    chmod -R u+w app-source
    substituteInPlace app-source/node_modules/@parcel/watcher/node_modules/detect-libc/lib/filesystem.js \
      --replace-fail "'/usr/bin/ldd'" "'${lib.getBin pkgs.glibc}/bin/ldd'"
    asar pack app-source usr/lib/chatgpt/resources/app.asar --unpack-dir node_modules
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib" "$out/bin" "$out/share"
    cp -a usr/lib/chatgpt "$out/lib/"
    cp -a usr/share/applications usr/share/pixmaps "$out/share/"

    # Use GTK integration; the optional Qt shims otherwise pull in two Qt stacks.
    rm "$out/lib/chatgpt/libqt5_shim.so" "$out/lib/chatgpt/libqt6_shim.so"
    # The vendor includes Node prebuilds for other operating systems and libcs.
    while IFS= read -r -d "" prebuild; do
      case "$(basename "$prebuild")" in
        linux-${nodeArch}|HID-linux-${nodeArch}|HID_hidraw-linux-${nodeArch}) ;;
        *) rm -r "$prebuild" ;;
      esac
    done < <(find "$out/lib/chatgpt" -type d -path '*/prebuilds/*' -prune -print0)
    find "$out/lib/chatgpt" -name '*.musl.node' -delete

    substituteInPlace "$out/share/applications/chatgpt.desktop" \
      --replace-fail 'Exec=chatgpt %U' "Exec=$out/bin/chatgpt %U"
    runHook postInstall
  '';

  preFixup = ''
    makeWrapper "$out/lib/chatgpt/ChatGPT" "$out/bin/chatgpt" \
      "''${gappsWrapperArgs[@]}" \
      --prefix PATH : ${lib.makeBinPath [ pkgs.xdg-utils ]}
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.nodejs ];
  installCheckPhase = ''
    runHook preInstallCheck
    node ${../tests/chatgpt-watcher.cjs} "$out/lib/chatgpt/resources/app.asar.unpacked/node_modules/@parcel/watcher"
    runHook postInstallCheck
  '';

  meta = {
    description = "Official ChatGPT desktop app with Codex for Linux";
    homepage = "https://developers.openai.com/docs/linux/linux-app";
    license = lib.licenses.unfree;
    mainProgram = "chatgpt";
    platforms = builtins.attrNames pin.assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

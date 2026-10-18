{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  makeWrapper,
  python3,
  dbus,
  xorg,
}:
let
  python = python3.withPackages (ps: [
    ps.xlib
    ps.dbus-python
    ps.pygobject3
  ]);
in
stdenvNoCC.mkDerivation {
  pname = "wine-sni-bridge";
  version = "unstable-2026-05-24";

  src = fetchFromGitHub {
    owner = "waliori";
    repo = "wine-sni-bridge";
    rev = "676c5dd2b9320c18c5c776e052791399dd43edc6";
    hash = "sha256-vP05dcrMH3KzqY7UEBjOLg1/vBjxRMs6LB/SKtbFsis=";
  };

  patches = [
    ../patches/wine-sni-bridge-niri.patch
    ../patches/wine-sni-bridge-recovery-menu.patch
  ];
  nativeBuildInputs = [
    makeWrapper
    dbus
    xorg.xorgserver
  ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    cp ${../scripts/gaming/wine-tray-menu.py} wine_tray_menu.py
    cp ${../scripts/gaming/battlenet-force-close.py} battlenet_processes.py
    export WINE_TRAY_MODULE_DIR="$PWD"
    # The build sandbox has no host /etc/dbus-1/session.conf.
    cat > session.conf <<'EOF'
    <busconfig>
      <type>session</type>
      <listen>unix:tmpdir=/tmp</listen>
      <policy context="default">
        <allow send_destination="*"/>
        <allow receive_sender="*"/>
        <allow own="*"/>
      </policy>
    </busconfig>
    EOF
    dbus-run-session --config-file="$PWD/session.conf" -- \
      ${python}/bin/python3 ${../tests/test_wine_tray_menu.py}
    Xvfb :99 -screen 0 800x600x24 -nolisten tcp >tray-xvfb.log 2>&1 &
    tray_xvfb_pid=$!
    trap 'kill "$tray_xvfb_pid" 2>/dev/null || true' EXIT
    export DISPLAY=:99
    for tray_attempt in $(seq 1 50); do
      test -S /tmp/.X11-unix/X99 && break
      sleep 0.1
    done
    ${python}/bin/python3 ${../tests/test_wine_tray_host.py} "$PWD/wine-sni-bridge.py"
    WINE_TOPOLOGY_MODULE=${../scripts/gaming/wine-display-topology.py} \
      WINE_SESSION_MODULE=${../scripts/gaming/wine-session.py} \
      ${python}/bin/python3 ${../tests/test_wine_display_topology.py}
    kill "$tray_xvfb_pid"
    wait "$tray_xvfb_pid" || true
    trap - EXIT
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm644 wine-sni-bridge.py "$out/libexec/wine-sni-bridge.py"
    install -Dm644 ${../scripts/gaming/wine-tray-menu.py} "$out/libexec/wine_tray_menu.py"
    install -Dm644 ${../scripts/gaming/battlenet-force-close.py} "$out/libexec/battlenet_processes.py"
    makeWrapper ${python}/bin/python3 "$out/bin/wine-sni-bridge" \
      --add-flags "$out/libexec/wine-sni-bridge.py" \
      --add-flags "--byte-order network"
    runHook postInstall
  '';

  meta = {
    description = "Expose Wine XEmbed icons to StatusNotifierItem trays";
    homepage = "https://github.com/waliori/wine-sni-bridge";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "wine-sni-bridge";
  };
}

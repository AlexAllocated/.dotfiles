{
  inputs,
  pkgs,
}:
let
  system = pkgs.stdenv.hostPlatform.system;
  # SceneFX otherwise advertises NVIDIA's 24-bit BGR readback preference to
  # screencopy clients, which PipeWire/WebRTC cannot negotiate.
  scenefx = inputs.mango.inputs.scenefx.packages.${system}.default.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ../patches/scenefx-xrgb8888-screencopy.patch ];
  });
  mango = inputs.mango.packages.${system}.mango.override { inherit scenefx; };
in
mango.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ../patches/mango-subsurface-window-capture.patch
    ../patches/mango-window-capture-repaint.patch
  ];
})

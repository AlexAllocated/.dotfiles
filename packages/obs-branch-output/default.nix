{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  pkg-config,
  obs-studio,
  qt6,
}:
stdenv.mkDerivation {
  pname = "obs-branch-output";
  version = "1.0.9";
  src = fetchFromGitHub {
    owner = "OPENSPHERE-Inc";
    repo = "branch-output";
    rev = "54bf83200496c0a6b1388a86bcd4f5a16cb33c4e";
    hash = "sha256-dnSRCQjVB7W93isFuW93NVQNllmRb3Xu8Vs5nFSeiOw=";
  };
  nativeBuildInputs = [
    cmake
    pkg-config
  ];
  buildInputs = [
    obs-studio
    qt6.qtbase
  ];
  dontWrapQtApps = true;
  meta = {
    description = "Independent OBS source and scene recording outputs";
    homepage = "https://github.com/OPENSPHERE-Inc/branch-output";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
}

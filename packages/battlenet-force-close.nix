{
  lib,
  writeShellScriptBin,
  python3,
  prefix,
}:
writeShellScriptBin "battlenet-force-close" ''
  exec ${lib.getExe python3} ${../scripts/gaming/battlenet-force-close.py} \
    --prefix ${lib.escapeShellArg prefix} "$@"
''

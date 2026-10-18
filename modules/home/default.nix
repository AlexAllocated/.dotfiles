{ ... }:
{
  # Native modules remain the configuration authority; capabilities group ownership.
  # Existing public module paths remain valid for legacy consumers.
  imports = [
    ./capabilities/foundation.nix
    ./capabilities/development.nix
    ./capabilities/editor.nix
    ./capabilities/desktop.nix
    ./capabilities/gaming.nix
  ];
}

# NixOS-WSL Rollout

NixOS is the primary WSL target. Keep an existing Ubuntu WSL distro installed
only as a fallback while validating a new NixOS setup.

## Install side-by-side

From the existing Ubuntu control-plane distro:

```sh
./dot-bootstrap nixos-wsl
```

The bootstrap installs a WSL distro named `NixOS` in `D:\WSL\NixOS` using the
latest `nixos.wsl` asset from NixOS-WSL.

## First apply

Inside the new distro:

```sh
git clone git@github.com:AlexAllocated/.dotfiles.git ~/.dotfiles
cd ~/.dotfiles
sudo nixos-rebuild boot --flake .#nixos-wsl
wsl.exe -t NixOS
dotctl doctor
```

## Cutover

After validation, run this from an elevated Windows PowerShell if Developer Mode
is not enabled:

```powershell
.\scripts\windows\apply-wsl-links.ps1 -DistroName NixOS
wsl.exe --set-default NixOS
```

Keep the Ubuntu distro until NixOS has handled normal work successfully.

## 1Password model

Shell startup intentionally avoids interactive authentication. Use these commands
directly when needed:

```sh
op vault list
gh auth login --web -h github.com
dotctl secrets
```

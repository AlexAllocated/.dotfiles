# NixOS-WSL Rollout

The current Ubuntu WSL distro stays installed until NixOS is validated.

## Install side-by-side

From the existing Ubuntu control-plane distro:

```sh
./dot-bootstrap nixos-wsl
```

The bootstrap installs a WSL distro named `NixOS` in `D:\WSL\NixOS` using the latest `nixos.wsl`
asset from NixOS-WSL.

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

After validation, run this from an elevated Windows PowerShell if Developer Mode is not enabled:

```powershell
.\scripts\windows\apply-wsl-links.ps1 -DistroName NixOS
wsl.exe --set-default NixOS
```

Keep the Ubuntu distro until NixOS has handled normal work successfully.

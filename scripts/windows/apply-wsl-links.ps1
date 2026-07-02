param(
   [string]$DistroName = "NixOS",
   [string]$LinuxHome = "/home/alex"
)

$ErrorActionPreference = "Stop"

function Normalize-WslTarget {
   param([string]$RelativePath)
   $relative = $RelativePath -replace "/", "\"
   return "\\wsl.localhost\$DistroName$($LinuxHome -replace '/', '\')\.dotfiles\$relative"
}

function Set-Symlink {
   param(
      [string]$Name,
      [string]$LinkPath,
      [string]$TargetPath
   )

   $parent = Split-Path -Parent $LinkPath
   if ($parent -and -not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
   }

   if (Test-Path -LiteralPath $LinkPath) {
      Remove-Item -LiteralPath $LinkPath -Recurse -Force
   }

   Write-Host "Linking $Name"
   New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath | Out-Null
}

Set-Symlink "WezTerm config" (Join-Path $env:USERPROFILE ".wezterm.lua") (Normalize-WslTarget ".wezterm.lua")
Set-Symlink "WezTerm directory" (Join-Path $env:USERPROFILE ".wezterm") (Normalize-WslTarget "wezterm")
Set-Symlink "Neovim config" (Join-Path $env:LOCALAPPDATA "nvim") (Normalize-WslTarget "nvim")
Set-Symlink "Komorebi config" (Join-Path $env:USERPROFILE "komorebi.json") (Normalize-WslTarget "komorebi/komorebi.json")
Set-Symlink "whkd config" (Join-Path $env:USERPROFILE ".config\whkdrc") (Normalize-WslTarget "komorebi/whkdrc")

Write-Host "Windows links now point at $DistroName."

param(
   [string]$DistroName = "NixOS",
   [string]$InstallLocation = "D:\WSL\NixOS",
   [string]$DownloadDirectory = "D:\Installers\NixOS-WSL",
   [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"

function Assert-Command {
   param([string]$Name)

   if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
      throw "Required command not found: $Name"
   }
}

Assert-Command "wsl.exe"

$existing = & wsl.exe --list --quiet | ForEach-Object { $_ -replace "`0", "" } | Where-Object { $_ -eq $DistroName }
if ($existing) {
   Write-Host "WSL distro '$DistroName' already exists; skipping install."
   exit 0
}

New-Item -ItemType Directory -Force -Path $InstallLocation | Out-Null
New-Item -ItemType Directory -Force -Path $DownloadDirectory | Out-Null

$release = Invoke-RestMethod -Uri "https://api.github.com/repos/nix-community/NixOS-WSL/releases/latest"
$asset = $release.assets | Where-Object { $_.name -eq "nixos.wsl" } | Select-Object -First 1
if (-not $asset) {
   throw "Unable to find nixos.wsl in latest NixOS-WSL release."
}

$imagePath = Join-Path $DownloadDirectory "nixos.wsl"
if (-not (Test-Path -LiteralPath $imagePath)) {
   Write-Host "Downloading $($asset.browser_download_url)"
   Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $imagePath
} else {
   Write-Host "Using existing image: $imagePath"
}

$arguments = @(
   "--install",
   "--from-file", $imagePath,
   "--name", $DistroName,
   "--location", $InstallLocation,
   "--no-launch"
)

Write-Host ("Installing NixOS-WSL: wsl.exe {0}" -f ($arguments -join " "))
& wsl.exe @arguments

if (-not $NoLaunch) {
   Write-Host "Launching $DistroName. Run 'passwd' if you keep passworded sudo; this repo disables wheel sudo password for the NixOS-WSL profile."
   & wsl.exe -d $DistroName
}

param(
   [string]$DistroName = "NixOS",
   [string]$InstallLocation = "",
   [string]$DownloadDirectory = "",
   [string]$Release = "2605.7.2",
   [string]$Sha256 = "e7180ad555fdcb8e1e057e2ef056de467603a5e502ff8531053738371be3f6b9",
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

if (-not $InstallLocation) {
   $InstallLocation = Join-Path $env:LOCALAPPDATA "WSL\$DistroName"
}
if (-not $DownloadDirectory) {
   $DownloadDirectory = Join-Path $env:LOCALAPPDATA "dotfiles\downloads"
}

$existing = & wsl.exe --list --quiet | ForEach-Object { $_ -replace "`0", "" } | Where-Object { $_ -eq $DistroName }
if ($existing) {
   Write-Host "WSL distro '$DistroName' already exists; skipping install."
   exit 0
}

New-Item -ItemType Directory -Force -Path $InstallLocation | Out-Null
New-Item -ItemType Directory -Force -Path $DownloadDirectory | Out-Null

$imagePath = Join-Path $DownloadDirectory "nixos-$Release.wsl"
$downloadUrl = "https://github.com/nix-community/NixOS-WSL/releases/download/$Release/nixos.wsl"
if (Test-Path -LiteralPath $imagePath) {
   $actual = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()
   if ($actual -ne $Sha256.ToLowerInvariant()) {
      Write-Host "Cached image checksum does not match; downloading it again."
      Remove-Item -LiteralPath $imagePath -Force
   }
}
if (-not (Test-Path -LiteralPath $imagePath)) {
   Write-Host "Downloading pinned NixOS-WSL $Release"
   Invoke-WebRequest -Uri $downloadUrl -OutFile $imagePath
}
$actual = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $Sha256.ToLowerInvariant()) {
   Remove-Item -LiteralPath $imagePath -Force
   throw "NixOS-WSL image checksum mismatch. Expected $Sha256, got $actual."
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

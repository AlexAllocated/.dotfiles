param(
   [string]$DistroName = "NixOS",
   [string]$InstallLocation = "",
   [string]$DownloadDirectory = "",
   [string]$Release = "2605.7.2",
   [string]$Sha256 = "e7180ad555fdcb8e1e057e2ef056de467603a5e502ff8531053738371be3f6b9",
   [switch]$EnsureWindowsFeatures,
   [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"

function Assert-Command {
   param([string]$Name)

   if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
      throw "Required command not found: $Name"
   }
}

function Test-Administrator {
   $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
   $principal = [Security.Principal.WindowsPrincipal]::new($identity)
   return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Enable-WslFeature {
   param([string]$Name)

   $feature = Get-WindowsOptionalFeature -Online -FeatureName $Name
   if ($feature.State -eq "Enabled") {
      Write-Host "Windows feature already enabled: $Name"
      return $false
   }
   if ($feature.State -eq "EnablePending") {
      Write-Host "Windows feature is pending a reboot: $Name"
      return $true
   }

   Write-Host "Enabling Windows feature: $Name"
   $result = Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart
   return [bool]$result.RestartNeeded
}

if ($EnsureWindowsFeatures) {
   if (-not (Test-Administrator)) {
      throw "-EnsureWindowsFeatures must be run from an elevated Windows PowerShell."
   }

   $restartNeeded = $false
   foreach ($featureName in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
      if (Enable-WslFeature $featureName) {
         $restartNeeded = $true
      }
   }
   if ($restartNeeded) {
      Write-Warning "WSL prerequisites are enabled, but Windows must reboot. Re-run this command after the reboot."
      exit 3010
   }
}

Assert-Command "wsl.exe"

if ($EnsureWindowsFeatures) {
   Write-Host "Updating the Windows Subsystem for Linux runtime."
   & wsl.exe --update
   if ($LASTEXITCODE -ne 0) {
      throw "wsl.exe --update failed with exit code $LASTEXITCODE."
   }
   & wsl.exe --set-default-version 2
   if ($LASTEXITCODE -ne 0) {
      throw "Could not set WSL 2 as the default version (exit code $LASTEXITCODE)."
   }
}

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

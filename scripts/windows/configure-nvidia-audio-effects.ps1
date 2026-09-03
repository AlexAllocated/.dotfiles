param(
   [string]$Version = "1.6.1.2",
   [string]$InstallerUrl = "https://international.download.nvidia.com/Windows/broadcast/sdk/AFX/2025-01-21_NVIDIA_AFX_SDK_Win_v1.6.1.2-GA_Blackwell.exe",
   [string]$InstallerSha256 = "84984D451D35076D54A86282DBF11775544B3A1DB2B58046DBC0D3376C015FF5",
   [string]$SignerThumbprint = "15F760D82C79D22446CC7D4806540BF632B1E104"
)

$ErrorActionPreference = "Stop"

trap {
   Write-Error $_
   exit 1
}

$installRoot = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVIDIA Audio Effects SDK"
$runtimeDll = Join-Path $installRoot "NVAudioEffects.dll"
$runtimeModel = Join-Path $installRoot "models\denoiser_48k.trtpkg"
$cacheRoot = Join-Path $env:LOCALAPPDATA "dotfiles\cache"
$installerPath = Join-Path $cacheRoot "nvidia-afx-$Version-blackwell.exe"

function Test-IsAdministrator {
   $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
   $principal = [Security.Principal.WindowsPrincipal]::new($identity)
   return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-AudioEffectsCurrent {
   return (
      (Test-Path -LiteralPath $runtimeDll -PathType Leaf) -and
      (Test-Path -LiteralPath $runtimeModel -PathType Leaf) -and
      (Get-Item -LiteralPath $runtimeDll).VersionInfo.FileVersion -eq $Version
   )
}

function Test-InstallerHash {
   return (
      (Test-Path -LiteralPath $installerPath -PathType Leaf) -and
      (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash -eq $InstallerSha256
   )
}

if (Test-AudioEffectsCurrent) {
   Write-Host "NVIDIA Audio Effects $Version for RTX 50-series GPUs is current."
   exit 0
}

if (Get-Process obs64 -ErrorAction SilentlyContinue) {
   throw "Close OBS before installing or updating NVIDIA Audio Effects $Version."
}

if (-not (Test-IsAdministrator)) {
   $scriptPath = $MyInvocation.MyCommand.Path
   if (-not $scriptPath) {
      throw "Cannot elevate NVIDIA Audio Effects reconciliation without a script path."
   }
   $arguments = @(
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", "`"$scriptPath`"",
      "-Version", "`"$Version`"",
      "-InstallerUrl", "`"$InstallerUrl`"",
      "-InstallerSha256", "`"$InstallerSha256`"",
      "-SignerThumbprint", "`"$SignerThumbprint`""
   )
   $process = Start-Process `
      -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -Verb RunAs `
      -Wait `
      -PassThru `
      -ArgumentList $arguments
   if ($process.ExitCode -ne 0) {
      throw "Elevated NVIDIA Audio Effects reconciliation exited with status $($process.ExitCode)."
   }
   if (-not (Test-AudioEffectsCurrent)) {
      throw "NVIDIA Audio Effects did not become current after elevated reconciliation."
   }
   Write-Host "Installed NVIDIA Audio Effects $Version for RTX 50-series GPUs."
   exit 0
}

New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
if (-not (Test-InstallerHash)) {
   Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
   Invoke-WebRequest -UseBasicParsing -Uri $InstallerUrl -OutFile $installerPath
}

$installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
if ($installerHash -ne $InstallerSha256) {
   throw "NVIDIA Audio Effects installer checksum mismatch: expected $InstallerSha256, received $installerHash."
}
$versionInfo = (Get-Item -LiteralPath $installerPath).VersionInfo
if ($versionInfo.CompanyName -ne "NVIDIA Corporation") {
   throw "NVIDIA Audio Effects installer metadata failed verification."
}
$signature = Get-AuthenticodeSignature -LiteralPath $installerPath
if (
   $signature.Status -ne "Valid" -or
   -not $signature.SignerCertificate -or
   $signature.SignerCertificate.Thumbprint -ne $SignerThumbprint
) {
   throw "NVIDIA Audio Effects installer signer failed verification."
}

$process = Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru
if ($process.ExitCode -ne 0 -and -not (Test-AudioEffectsCurrent)) {
   throw "NVIDIA Audio Effects installer exited with status $($process.ExitCode)."
}
if (-not (Test-AudioEffectsCurrent)) {
   throw "NVIDIA Audio Effects $Version was not detected after installation."
}

Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
Write-Host "Installed NVIDIA Audio Effects $Version for RTX 50-series GPUs."

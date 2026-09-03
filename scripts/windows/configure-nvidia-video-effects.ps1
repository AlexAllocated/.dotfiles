param(
   [string]$Version = "0.7.6.0",
   [string]$InstallerUrl = "https://international.download.nvidia.com/Windows/broadcast/sdk/VFX/nvidia_video_effects_sdk_installer_v0.7.6_blackwell.exe",
   [string]$InstallerSha256 = "CEF45592E16D0EA91DBFF12A828B31874AB83829ADF9A431466DFB88B714618D",
   [string]$SignerThumbprint = "F3F62BE053B6812E2E1AEC4EA8EB7FB4B955B5AB"
)

$ErrorActionPreference = "Stop"

trap {
   Write-Error $_
   exit 1
}

$installRoot = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVIDIA Video Effects"
$runtimeDll = Join-Path $installRoot "NVVideoEffects.dll"

function Test-IsAdministrator {
   $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
   $principal = [Security.Principal.WindowsPrincipal]::new($identity)
   return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-VideoEffectsCurrent {
   if (-not (Test-Path -LiteralPath $runtimeDll -PathType Leaf)) {
      return $false
   }
   # NVIDIA labels this package 0.7.6 even though NVVideoEffects.dll reports
   # an internal ProductVersion of 0.8.1. Use its FileVersion, which matches
   # the package and uninstall-registration version.
   return (Get-Item -LiteralPath $runtimeDll).VersionInfo.FileVersion -eq $Version
}

if (Test-VideoEffectsCurrent) {
   Write-Host "NVIDIA Video Effects $Version for RTX 50-series GPUs is current."
   exit 0
}

if (Get-Process obs64 -ErrorAction SilentlyContinue) {
   throw "Close OBS before installing or updating NVIDIA Video Effects $Version."
}

if (-not (Test-IsAdministrator)) {
   $scriptPath = $MyInvocation.MyCommand.Path
   if (-not $scriptPath) {
      throw "Cannot elevate NVIDIA Video Effects reconciliation without a script path."
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
      throw "Elevated NVIDIA Video Effects reconciliation exited with status $($process.ExitCode)."
   }
   if (-not (Test-VideoEffectsCurrent)) {
      throw "NVIDIA Video Effects did not become current after elevated reconciliation."
   }
   Write-Host "Installed NVIDIA Video Effects $Version for RTX 50-series GPUs."
   exit 0
}

$temporaryRoot = Join-Path $env:TEMP "dotfiles-nvidia-video-effects-$([guid]::NewGuid().ToString('N'))"
$installerPath = Join-Path $temporaryRoot "nvidia-video-effects.exe"
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
   Invoke-WebRequest -UseBasicParsing -Uri $InstallerUrl -OutFile $installerPath
   $installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
   if ($installerHash -ne $InstallerSha256) {
      throw "NVIDIA Video Effects installer checksum mismatch: expected $InstallerSha256, received $installerHash."
   }

   $versionInfo = (Get-Item -LiteralPath $installerPath).VersionInfo
   if ($versionInfo.CompanyName -ne "NVIDIA Corporation" -or $versionInfo.ProductVersion -ne $Version) {
      throw "NVIDIA Video Effects installer metadata failed verification."
   }
   $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
   if (
      -not $signature.SignerCertificate -or
      $signature.SignerCertificate.Thumbprint -ne $SignerThumbprint
   ) {
      throw "NVIDIA Video Effects installer signer failed verification."
   }

   $process = Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru
   # This NVIDIA NSIS package can return 1 after successfully installing.
   # Treat the verified runtime as the authority and only fail when both the
   # process and the post-install check indicate failure.
   if ($process.ExitCode -ne 0 -and -not (Test-VideoEffectsCurrent)) {
      throw "NVIDIA Video Effects installer exited with status $($process.ExitCode)."
   }
} finally {
   Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-VideoEffectsCurrent)) {
   throw "NVIDIA Video Effects $Version was not detected after installation."
}

Write-Host "Installed NVIDIA Video Effects $Version for RTX 50-series GPUs."

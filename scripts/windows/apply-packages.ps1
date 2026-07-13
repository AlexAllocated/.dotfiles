param(
   [Parameter(Mandatory = $true)]
   [string]$ManifestPath
)

$ErrorActionPreference = "Stop"

trap {
   Write-Error $_
   exit 1
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
   throw "WinGet manifest not found: $ManifestPath"
}
$wingetPath = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
if (-not (Test-Path -LiteralPath $wingetPath)) {
   throw "WinGet is unavailable. Install or repair Microsoft's App Installer, then rerun dotctl."
}

# WinGet does not reliably consume a WSL UNC path, so give it a Windows-local copy.
$temporaryManifest = Join-Path $env:TEMP "dotfiles-winget-$([guid]::NewGuid().ToString('N')).json"
Copy-Item -LiteralPath $ManifestPath -Destination $temporaryManifest -Force

try {
   Write-Host "Reconciling Windows applications from $ManifestPath..."
   $arguments = @(
      "import",
      "--import-file", $temporaryManifest,
      "--ignore-versions",
      "--accept-package-agreements",
      "--accept-source-agreements",
      "--disable-interactivity"
   )
   $process = Start-Process `
      -FilePath $wingetPath `
      -ArgumentList $arguments `
      -NoNewWindow `
      -PassThru `
      -Wait
   if ($process.ExitCode -ne 0) {
      throw "WinGet import failed with exit code $($process.ExitCode)."
   }
} finally {
   Remove-Item -LiteralPath $temporaryManifest -Force -ErrorAction SilentlyContinue
}

Write-Host "Windows applications are current."

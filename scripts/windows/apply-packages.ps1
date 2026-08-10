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
   # Synapse 4 registers its installed application under a generic ARP entry
   # rather than the WinGet bootstrapper ID. Once the real app is present,
   # remove the bootstrapper from the temporary import so every apply does not
   # launch Razer's installer again.
   $razerEngine = Join-Path $env:ProgramFiles "Razer\RazerAppEngine\RazerAppEngine.exe"
   if (Test-Path -LiteralPath $razerEngine) {
      $razerBootstrapId = "RazerInc.RazerInstaller.Synapse4"
      $temporaryPackages = Get-Content -LiteralPath $temporaryManifest -Raw | ConvertFrom-Json
      foreach ($source in $temporaryPackages.Sources) {
         $source.Packages = @($source.Packages | Where-Object {
            $_.PackageIdentifier -ne $razerBootstrapId
         })
      }
      $temporaryPackages | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryManifest -Encoding UTF8
   }

   # Battle.net's WinGet manifest requires an install root and otherwise tries
   # to prompt, which breaks the unattended full-manifest import below.
   $battleNetId = "Blizzard.BattleNet"
   $listProcess = Start-Process `
      -FilePath $wingetPath `
      -ArgumentList @(
         "list",
         "--id", $battleNetId,
         "--exact",
         "--source", "winget",
         "--accept-source-agreements",
         "--disable-interactivity"
      ) `
      -NoNewWindow `
      -PassThru `
      -Wait
   if ($listProcess.ExitCode -eq 20) {
      $battleNetLocation = Join-Path ${env:ProgramFiles(x86)} "Battle.net"
      Write-Host "Installing Battle.net at $battleNetLocation..."
      $battleNetProcess = Start-Process `
         -FilePath $wingetPath `
         -ArgumentList @(
            "install",
            "--id", $battleNetId,
            "--exact",
            "--source", "winget",
            "--location", "`"$battleNetLocation`"",
            "--accept-package-agreements",
            "--accept-source-agreements",
            "--disable-interactivity"
         ) `
         -NoNewWindow `
         -PassThru `
         -Wait
      if ($battleNetProcess.ExitCode -ne 0) {
         throw "Battle.net WinGet bootstrap failed with exit code $($battleNetProcess.ExitCode)."
      }
   } elseif ($listProcess.ExitCode -ne 0) {
      throw "Could not determine Battle.net's installation state (WinGet exit code $($listProcess.ExitCode))."
   }

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

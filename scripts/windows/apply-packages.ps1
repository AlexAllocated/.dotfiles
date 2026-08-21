param(
   [Parameter(Mandatory = $true)]
   [string]$ManifestPath
)

$ErrorActionPreference = "Stop"

trap {
   Write-Error $_
   exit 1
}

function Test-IsAdministrator {
   $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
   $principal = [Security.Principal.WindowsPrincipal]::new($identity)
   return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-WinGetAsInteractiveUser {
   param(
      [Parameter(Mandatory = $true)]
      [string]$WinGetPath,

      [Parameter(Mandatory = $true)]
      [string[]]$ArgumentList
   )

   $taskName = "Dotfiles WinGet User Reconcile $([guid]::NewGuid().ToString('N'))"
   $logPath = Join-Path $env:TEMP "$($taskName.Replace(' ', '-')).log"
   $quotedArguments = @($ArgumentList | ForEach-Object {
      "'$($_.Replace("'", "''"))'"
   }) -join ", "
   $quotedWinGetPath = $WinGetPath.Replace("'", "''")
   $quotedLogPath = $logPath.Replace("'", "''")
   $payload = @"
& '$quotedWinGetPath' @($quotedArguments) *> '$quotedLogPath'
exit `$LASTEXITCODE
"@
   $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
   $action = New-ScheduledTaskAction `
      -Execute "powershell.exe" `
      -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedPayload"
   $principal = New-ScheduledTaskPrincipal `
      -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
      -LogonType Interactive `
      -RunLevel Limited

   try {
      Register-ScheduledTask `
         -TaskName $taskName `
         -Action $action `
         -Principal $principal `
         -Force | Out-Null
      $startedAt = Get-Date
      Start-ScheduledTask -TaskName $taskName
      $deadline = $startedAt.AddMinutes(20)
      do {
         Start-Sleep -Milliseconds 500
         $task = Get-ScheduledTask -TaskName $taskName
         $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
         # Task Scheduler rounds LastRunTime to whole seconds, so comparing it
         # to the millisecond-precise start timestamp can remain false forever.
         $hasStarted = $taskInfo.LastRunTime.Year -gt 2000
      } while ((-not $hasStarted -or $task.State -eq "Running") -and (Get-Date) -lt $deadline)

      if (-not $hasStarted -or $task.State -eq "Running") {
         Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
         throw "Timed out while reconciling a per-user WinGet package."
      }

      if (Test-Path -LiteralPath $logPath) {
         Get-Content -LiteralPath $logPath | Write-Host
      }
      # Different Task Scheduler builds expose WinGet HRESULTs as either a
      # signed Int32 or its equivalent unsigned value.
      $noApplicableUpgradeSigned = [int64]-1978335189
      $noApplicableUpgradeUnsigned = [int64]2316632107
      $taskResult = [int64]$taskInfo.LastTaskResult
      if (
         $taskResult -ne 0 -and
         $taskResult -ne $noApplicableUpgradeSigned -and
         $taskResult -ne $noApplicableUpgradeUnsigned
      ) {
         throw "Per-user WinGet reconciliation failed with exit code $taskResult."
      }
   } finally {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
   }
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
   throw "WinGet manifest not found: $ManifestPath"
}
$wingetPath = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
if (-not (Test-Path -LiteralPath $wingetPath)) {
   throw "WinGet is unavailable. Install or repair Microsoft's App Installer, then rerun dotctl."
}

# The community catalog can otherwise remain stale across repeated applies.
# Refresh it before the versionless import so every declared package resolves
# to the newest version currently published by its source.
$sourceUpdateProcess = Start-Process `
   -FilePath $wingetPath `
   -ArgumentList @(
      "source",
      "update",
      "--disable-interactivity"
   ) `
   -NoNewWindow `
   -PassThru `
   -Wait
if ($sourceUpdateProcess.ExitCode -ne 0) {
   throw "WinGet source refresh failed with exit code $($sourceUpdateProcess.ExitCode)."
}

# WinGet does not reliably consume a WSL UNC path, so give it a Windows-local copy.
$temporaryManifest = Join-Path $env:TEMP "dotfiles-winget-$([guid]::NewGuid().ToString('N')).json"
Copy-Item -LiteralPath $ManifestPath -Destination $temporaryManifest -Force

try {
   $temporaryPackages = Get-Content -LiteralPath $temporaryManifest -Raw | ConvertFrom-Json
   $manifestChanged = $false

   # Synapse 4 registers its installed application under a generic ARP entry
   # rather than the WinGet bootstrapper ID. Once the real app is present,
   # remove the bootstrapper from the temporary import so every apply does not
   # launch Razer's installer again.
   $razerEngine = Join-Path $env:ProgramFiles "Razer\RazerAppEngine\RazerAppEngine.exe"
   if (Test-Path -LiteralPath $razerEngine) {
      $razerBootstrapId = "RazerInc.RazerInstaller.Synapse4"
      foreach ($source in $temporaryPackages.Sources) {
         $source.Packages = @($source.Packages | Where-Object {
            $_.PackageIdentifier -ne $razerBootstrapId
         })
      }
      $manifestChanged = $true
   }

   # Discord's Squirrel full installer tries to replace the complete per-user
   # application directory. It fails the entire manifest import when Discord
   # has that directory open, so defer only its upgrade until a later apply
   # instead of killing an active call or blocking unrelated integration.
   if (Get-Process -Name "Discord" -ErrorAction SilentlyContinue) {
      $discordId = "Discord.Discord"
      foreach ($source in $temporaryPackages.Sources) {
         $source.Packages = @($source.Packages | Where-Object {
            $_.PackageIdentifier -ne $discordId
         })
      }
      $manifestChanged = $true
      Write-Host "Discord is running; deferring its WinGet upgrade until the next apply after Discord exits."
   }

   # Spotify is a per-user package whose installer refuses an administrator
   # token. WSL can inherit an elevated Windows token, so reconcile Spotify in
   # a short-lived limited-token task and keep the main import deterministic.
   $perUserPackages = @()
   if (Test-IsAdministrator) {
      $perUserPackageIds = @("Spotify.Spotify")
      foreach ($source in $temporaryPackages.Sources) {
         $sourceName = $source.SourceDetails.Name
         foreach ($package in @($source.Packages)) {
            if ($package.PackageIdentifier -in $perUserPackageIds) {
               $perUserPackages += [pscustomobject]@{
                  Id = $package.PackageIdentifier
                  Source = $sourceName
               }
            }
         }
         $source.Packages = @($source.Packages | Where-Object {
            $_.PackageIdentifier -notin $perUserPackageIds
         })
      }
      $manifestChanged = $perUserPackages.Count -gt 0 -or $manifestChanged
   }

   if ($manifestChanged) {
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

   foreach ($package in $perUserPackages) {
      Write-Host "Reconciling per-user package $($package.Id)..."
      Invoke-WinGetAsInteractiveUser `
         -WinGetPath $wingetPath `
         -ArgumentList @(
            "install",
            "--id", $package.Id,
            "--exact",
            "--source", $package.Source,
            "--accept-package-agreements",
            "--accept-source-agreements",
            "--disable-interactivity"
         )
   }
} finally {
   Remove-Item -LiteralPath $temporaryManifest -Force -ErrorAction SilentlyContinue
}

Write-Host "Windows applications are current."

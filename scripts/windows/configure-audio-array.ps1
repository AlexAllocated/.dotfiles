param(
   [Parameter(Mandatory = $true)]
   [string]$SourceDirectory,

   [string]$VacInstallerPath = "",

   [switch]$OpenVacDownload
)

$ErrorActionPreference = "Stop"

trap {
   Write-Error $_
   exit 1
}

$applicationRoot = Join-Path $env:LOCALAPPDATA "AudioArray"
$buildRoot = Join-Path $applicationRoot "build"
$binaryRoot = Join-Path $applicationRoot "bin"
$binaryPath = Join-Path $binaryRoot "audioarray.exe"
$uiBinaryPath = Join-Path $binaryRoot "audioarray-ui.exe"
$configRoot = Join-Path $env:APPDATA "AudioArray"
$configPath = Join-Path $configRoot "config.toml"
$logRoot = Join-Path $applicationRoot "logs"
$logPath = Join-Path $logRoot "audioarray.log"
$launcherPath = Join-Path $applicationRoot "run-audioarray.vbs"
$stampPath = Join-Path $applicationRoot "source.sha256"
$endpointConfiguratorSource = Join-Path $PSScriptRoot "configure-audioarray-endpoints.ps1"
$endpointConfiguratorPath = Join-Path $applicationRoot "configure-audioarray-endpoints.ps1"
$endpointConfiguratorLogPath = Join-Path $logRoot "configure-audioarray-endpoints.log"
$taskName = "AudioArray"
$vacRegistryPath = "HKLM:\SOFTWARE\EuMus Design\Virtual Audio Cable\4"
$vacDownloadUrl = "https://vac.muzychenko.net/en/download.htm"
$cargoPath = Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe"
$vswherePath = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$manifestPath = Join-Path $SourceDirectory "Cargo.toml"
$uiManifestPath = Join-Path $SourceDirectory "ui\src-tauri\Cargo.toml"
$uiEntryPath = Join-Path $SourceDirectory "ui\dist\index.html"
$uiShortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\AudioArray.lnk"
$exampleConfigPath = Join-Path $SourceDirectory "config.example.toml"

function Test-IsAdministrator {
   $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
   $principal = [Security.Principal.WindowsPrincipal]::new($identity)
   return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SourceHash {
   param([Parameter(Mandatory = $true)][string]$Root)

   $relativePaths = @("Cargo.toml", "Cargo.lock", "config.example.toml")
   $relativePaths += Get-ChildItem -LiteralPath (Join-Path $Root "src") -File -Recurse |
      ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart("\") }
   $relativePaths += Get-ChildItem -LiteralPath (Join-Path $Root "ui") -File -Recurse |
      Where-Object { $_.FullName -notmatch '\\src-tauri\\(gen|target)\\' } |
      ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart("\") }
   $hashText = foreach ($relativePath in $relativePaths | Sort-Object) {
      $path = Join-Path $Root $relativePath
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
         throw "AudioArray source file is missing: $path"
      }
      "{0}  {1}" -f (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash, $relativePath
   }
   $bytes = [Text.Encoding]::UTF8.GetBytes(($hashText -join "`n"))
   $sha = [Security.Cryptography.SHA256]::Create()
   try {
      return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
   } finally {
      $sha.Dispose()
   }
}

function Assert-NativeBuildTools {
   if (-not (Test-Path -LiteralPath $cargoPath -PathType Leaf)) {
      throw "Windows Rust is missing. Reconcile the WinGet manifest, then rerun this script."
   }
   if (-not (Test-Path -LiteralPath $vswherePath -PathType Leaf)) {
      throw "Visual Studio Build Tools are missing. Reconcile the WinGet manifest, then rerun this script."
   }
   $installationPath = & $vswherePath `
      -latest `
      -products * `
      -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
      -property installationPath
   if (-not $installationPath) {
      throw @"
The Visual Studio C++ workload is missing. Modify "Visual Studio Build Tools
2022" and install "Desktop development with C++", then rerun dotctl apply.
"@
   }
}

function Invoke-CargoReleaseBuild {
   param([Parameter(Mandatory = $true)][string]$CargoManifestPath)

   # Windows PowerShell can promote Cargo's ordinary stderr progress stream to
   # a terminating NativeCommandError when this script is launched through
   # WSL. Start-Process preserves the native exit code without misclassifying
   # successful compiler diagnostics as a PowerShell failure.
   $process = Start-Process `
      -FilePath $cargoPath `
      -ArgumentList @(
         "build",
         "--release",
         "--locked",
         "--manifest-path",
         $CargoManifestPath
      ) `
      -NoNewWindow `
      -PassThru
   # Start-Process -Wait follows the complete descendant process tree. Rust's
   # Windows linker can leave an inherited console handle alive after Cargo
   # itself exits, which makes that tree wait hang indefinitely. Wait on the
   # Cargo process handle directly instead. Materialize Handle before waiting;
   # Windows PowerShell otherwise releases it early and reports no exit code.
   $null = $process.Handle
   $process.WaitForExit()
   $process.Refresh()
   if ($process.ExitCode -ne 0) {
      throw "Cargo release build failed for $CargoManifestPath with exit code $($process.ExitCode)."
   }
}

function Assert-AudioArrayApplicationPolicy {
   param([Parameter(Mandatory = $true)][string]$InterfacePath)

   $defenderStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
   if (-not $defenderStatus -or $defenderStatus.SmartAppControlState -ne "On") {
      return
   }
   $signature = Get-AuthenticodeSignature -LiteralPath $InterfacePath
   if ($signature.Status -eq "Valid") {
      return
   }
   throw @"
Smart App Control is enforcing and the locally-built AudioArray interface is
not signed by a certificate in Microsoft's Trusted Root Program. Windows will
block this binary. The currently running graph was left untouched.

This developer workstation can either disable Smart App Control while keeping
Defender, SmartScreen, Secure Boot, and TPM protections enabled, or AudioArray
must be signed through a trusted code-signing provider before installation.
"@
}

function Stop-AudioArray {
   Get-Process audioarray-ui -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -eq $uiBinaryPath } |
      Stop-Process -Force
   Get-Process audioarray -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -eq $binaryPath } |
      Stop-Process -Force
   Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}

function Test-FileEqual {
   param(
      [Parameter(Mandatory = $true)][string]$Source,
      [Parameter(Mandatory = $true)][string]$Destination
   )

   return (
      (Test-Path -LiteralPath $Destination -PathType Leaf) -and
      (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -eq
         (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
   )
}

function Test-AudioArrayRunning {
   $interface = Get-Process audioarray-ui -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -eq $uiBinaryPath } |
      Select-Object -First 1
   $engine = Get-Process audioarray -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -eq $binaryPath } |
      Select-Object -First 1
   return [bool]($interface -and $engine)
}

function Test-AudioArrayTaskCurrent {
   $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
   return [bool](
      $task -and
      $task.Actions.Count -eq 1 -and
      $task.Actions[0].Execute -ieq $uiBinaryPath -and
      $task.Actions[0].Arguments -eq "--tray" -and
      $task.Principal.RunLevel.ToString() -eq "Limited" -and
      $task.Triggers.Count -eq 1 -and
      $task.Triggers[0].CimClass.CimClassName -eq "MSFT_TaskLogonTrigger" -and
      $task.Settings.ExecutionTimeLimit -eq "PT0S" -and
      $task.Settings.MultipleInstances.ToString() -eq "IgnoreNew" -and
      $task.Settings.Priority -eq 4 -and
      $task.Settings.RestartCount -eq 5 -and
      $task.Settings.RestartInterval -eq "PT1M"
   )
}

function Install-AudioArrayShortcut {
   $shell = New-Object -ComObject WScript.Shell
   try {
      $shortcut = $shell.CreateShortcut($uiShortcutPath)
      if (
         (Test-Path -LiteralPath $uiShortcutPath -PathType Leaf) -and
         $shortcut.TargetPath -ieq $uiBinaryPath -and
         $shortcut.WorkingDirectory -ieq $binaryRoot -and
         $shortcut.IconLocation -ieq "$uiBinaryPath,0" -and
         $shortcut.Description -eq "AudioArray Intrepid operations console"
      ) {
         return $false
      }
      $shortcut.TargetPath = $uiBinaryPath
      $shortcut.WorkingDirectory = $binaryRoot
      $shortcut.IconLocation = "$uiBinaryPath,0"
      $shortcut.Description = "AudioArray Intrepid operations console"
      $shortcut.Save()
      return $true
   } finally {
      [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
   }
}

function Get-VacEndpoints {
   $audioRoot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio"
   $friendlyNameProperty = "{a45c254e-df1c-4efd-8020-67d146a850e0},2"
   $deviceNameProperty = "{b3f8fa53-0004-438e-9003-51a46e139bfc},6"
   $backingPathProperty = "{233164c8-1b2c-4c7d-bc68-b671687a2567},1"

   foreach ($direction in @("Render", "Capture")) {
      $directionRoot = Join-Path $audioRoot $direction
      foreach ($endpoint in Get-ChildItem -LiteralPath $directionRoot -ErrorAction SilentlyContinue) {
         $propertiesPath = Join-Path $endpoint.PSPath "Properties"
         if (-not (Test-Path -LiteralPath $propertiesPath)) {
            continue
         }
         $properties = Get-ItemProperty -LiteralPath $propertiesPath
         if ($properties.$deviceNameProperty -ne "Virtual Audio Cable") {
            continue
         }
         $currentName = [string]$properties.$friendlyNameProperty
         if ($currentName -notmatch '^Line [1-4]$' -and $currentName -notmatch '^AudioArray (Game|Comms|Music|Clean Mic)$') {
            continue
         }
         $backingPath = [string]$properties.$backingPathProperty
         if ($backingPath -notmatch '\\wave(?<Cable>[1-4])_[rc]_rt') {
            continue
         }
         [pscustomobject]@{
            Cable = [int]$Matches.Cable
            Direction = $direction
            Name = $currentName
            ItemId = if ($direction -eq "Render") {
               "{0.0.0.00000000}.$($endpoint.PSChildName)"
            } else {
               "{0.0.1.00000000}.$($endpoint.PSChildName)"
            }
         }
      }
   }
}

function Get-SoundVolumeViewPath {
   $command = Get-Command SoundVolumeView.exe -ErrorAction SilentlyContinue
   if ($command) {
      return $command.Source
   }
   $packageRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
   $candidate = Get-ChildItem `
      -LiteralPath $packageRoot `
      -Filter "SoundVolumeView.exe" `
      -File `
      -Recurse `
      -ErrorAction SilentlyContinue |
      Select-Object -First 1 -ExpandProperty FullName
   if (-not $candidate) {
      throw "SoundVolumeView is missing. Reconcile the WinGet manifest, then rerun this script."
   }
   return $candidate
}

function Assert-AudioArrayEndpointNames {
   $expected = @{
      1 = "AudioArray Game"
      2 = "AudioArray Comms"
      3 = "AudioArray Music"
      4 = "AudioArray Clean Mic"
   }
   $endpoints = @(Get-VacEndpoints)
   $incorrect = foreach ($direction in @("Render", "Capture")) {
      foreach ($cable in 1..4) {
         $endpoint = $endpoints | Where-Object {
            $_.Direction -eq $direction -and $_.Cable -eq $cable
         } | Select-Object -First 1
         if (-not $endpoint -or $endpoint.Name -ne $expected[$cable]) {
            "$direction cable $cable"
         }
      }
   }
   if (-not $incorrect) {
      Write-Host "AudioArray endpoint names are current."
      return $false
   }

   if (-not (Test-FileEqual -Source $endpointConfiguratorSource -Destination $endpointConfiguratorPath)) {
      Copy-Item -LiteralPath $endpointConfiguratorSource -Destination $endpointConfiguratorPath -Force
   }
   & powershell.exe `
      -NoLogo `
      -NoProfile `
      -ExecutionPolicy Bypass `
      -File $endpointConfiguratorPath `
      -LogPath $endpointConfiguratorLogPath
   if ($LASTEXITCODE -ne 0) {
      $details = if (Test-Path -LiteralPath $endpointConfiguratorLogPath) {
         (Get-Content -LiteralPath $endpointConfiguratorLogPath -Raw).Trim()
      } else {
         "No endpoint-policy error log was produced."
      }
      throw "AudioArray endpoint naming failed with exit code $LASTEXITCODE.`n$details"
   }

   $remaining = @(Get-VacEndpoints | Where-Object {
      $_.Name -ne $expected[$_.Cable]
   })
   if ($remaining) {
      throw "Windows did not retain every AudioArray endpoint name."
   }
   Write-Host "Reconciled AudioArray endpoint names."
   return $true
}

function Set-AudioArraySpatialFormats {
   $soundVolumeView = Get-SoundVolumeViewPath
   $renderEndpoints = @(Get-VacEndpoints | Where-Object Direction -eq "Render")
   $formats = @(
      [pscustomobject]@{
         Cable = 1
         Name = "DTS Headphone:X"
         Guid = [Windows.Media.Audio.SpatialAudioFormatSubtype, Windows.Media.Audio, ContentType = WindowsRuntime]::DTSHeadphoneX
      },
      [pscustomobject]@{
         Cable = 3
         Name = "Dolby Atmos for Headphones"
         Guid = [Windows.Media.Audio.SpatialAudioFormatSubtype, Windows.Media.Audio, ContentType = WindowsRuntime]::DolbyAtmosForHeadphones
      }
   )

   $exportPath = Join-Path $env:TEMP "audioarray-spatial-$([guid]::NewGuid().ToString('N')).csv"

   function Get-SpatialItems {
      Remove-Item -LiteralPath $exportPath -Force -ErrorAction SilentlyContinue
      Start-Process `
         -FilePath $soundVolumeView `
         -ArgumentList @("/scomma", "`"$exportPath`"") `
         -Wait | Out-Null
      return @(Import-Csv -LiteralPath $exportPath)
   }

   $changed = $false
   try {
      $soundItems = @(Get-SpatialItems)
      foreach ($format in $formats) {
         $endpoint = $renderEndpoints | Where-Object Cable -eq $format.Cable | Select-Object -First 1
         if (-not $endpoint) {
            throw "Could not find VAC render cable $($format.Cable) for $($format.Name)."
         }
         $soundItem = $soundItems | Where-Object { $_."Item ID" -eq $endpoint.ItemId } | Select-Object -First 1
         $expectedGuid = ([guid]$format.Guid).ToString("B").ToUpperInvariant()
         if ($soundItem -and $soundItem."Spatial Guid".ToUpperInvariant() -eq $expectedGuid) {
            continue
         }

         $process = Start-Process `
            -FilePath $soundVolumeView `
            -ArgumentList @(
               "/SetSpatial",
               "`"$($endpoint.ItemId)`"",
               "`"$($format.Name)`""
            ) `
            -Wait `
            -PassThru
         if ($process.ExitCode -ne 0) {
            throw "SoundVolumeView failed to set $($format.Name) on $($endpoint.Name)."
         }
         $changed = $true
      }

      if ($changed) {
         Start-Sleep -Seconds 1
         $soundItems = @(Get-SpatialItems)
      }
      foreach ($format in $formats) {
         $endpoint = $renderEndpoints | Where-Object Cable -eq $format.Cable | Select-Object -First 1
         $soundItem = $soundItems | Where-Object { $_."Item ID" -eq $endpoint.ItemId } | Select-Object -First 1
         $expectedGuid = ([guid]$format.Guid).ToString("B").ToUpperInvariant()
         if (-not $soundItem -or $soundItem."Spatial Guid".ToUpperInvariant() -ne $expectedGuid) {
            throw @"
$($format.Name) is installed but Windows did not activate it on $($endpoint.Name).
Open its Microsoft Store companion app once while signed into the account that
owns the license, then rerun dotctl apply.
"@
         }
      }
      if ($changed) {
         Write-Host "Reconciled AudioArray spatial formats."
      } else {
         Write-Host "AudioArray spatial formats are current."
      }
   } finally {
      Remove-Item -LiteralPath $exportPath -Force -ErrorAction SilentlyContinue
   }
   return $changed
}

function Set-AudioArrayUnityGain {
   $soundVolumeView = Get-SoundVolumeViewPath
   $exportPath = Join-Path $env:TEMP "audioarray-levels-$([guid]::NewGuid().ToString('N')).csv"

   function Get-AudioArrayLevelItems {
      Remove-Item -LiteralPath $exportPath -Force -ErrorAction SilentlyContinue
      Start-Process `
         -FilePath $soundVolumeView `
         -ArgumentList @("/scomma", "`"$exportPath`"") `
         -Wait | Out-Null
      return @(Import-Csv -LiteralPath $exportPath | Where-Object {
         $_."Device Name" -eq "Virtual Audio Cable" -and (
            ($_.Type -eq "Device" -and $_.Name -match '^AudioArray (Game|Comms|Music|Clean Mic)$') -or
            $_.Type -eq "Subunit"
         )
      })
   }

   function Test-UnityGain {
      param([Parameter(Mandatory = $true)]$Item)

      $levels = if ($Item.Type -eq "Device") {
         @($Item."Volume dB")
      } else {
         @($Item."Channels dB" -split ',')
      }
      return @($levels | Where-Object { $_.Trim() -ne "0.00 dB" }).Count -eq 0
   }

   try {
      $items = @(Get-AudioArrayLevelItems)
      if ($items.Count -lt 16) {
         throw "Expected at least 16 AudioArray endpoint and pin gain stages; found $($items.Count)."
      }
      $itemsToUpdate = @($items | Where-Object { -not (Test-UnityGain -Item $_) })
      if ($itemsToUpdate.Count -eq 0) {
         Write-Host "All AudioArray endpoint and Main pin gain stages are already at 0.00 dB."
         return $false
      }
      foreach ($item in $itemsToUpdate) {
         $arguments = @(
            "/SetVolumeDecibel",
            "`"$($item.'Item ID')`"",
            "0"
         )
         $process = Start-Process `
            -FilePath $soundVolumeView `
            -ArgumentList $arguments `
            -Wait `
            -PassThru
         if ($process.ExitCode -ne 0) {
            throw "SoundVolumeView failed to set unity gain on $($item.Name)."
         }
      }

      Start-Sleep -Seconds 1
      $remaining = @(Get-AudioArrayLevelItems | Where-Object { -not (Test-UnityGain -Item $_) })
      if ($remaining) {
         $descriptions = $remaining | ForEach-Object {
            "$($_.Name) [$($_.Direction)]"
         }
         throw "AudioArray gain verification failed for: $($descriptions -join ', ')."
      }
      Write-Host "Reconciled $($itemsToUpdate.Count) AudioArray gain stage(s) to 0.00 dB."
   } finally {
      Remove-Item -LiteralPath $exportPath -Force -ErrorAction SilentlyContinue
   }
   return $true
}

function Assert-VacInstaller {
   param([Parameter(Mandatory = $true)][string]$Path)

   if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      throw "VAC installer not found: $Path"
   }
   $signature = Get-AuthenticodeSignature -LiteralPath $Path
   if ($signature.Status -ne "Valid") {
      throw "Refusing VAC installer with Authenticode status $($signature.Status): $Path"
   }
   if ($signature.SignerCertificate.Subject -notmatch "Muzychenko|EuMus") {
      throw "Refusing unexpected VAC signer $($signature.SignerCertificate.Subject): $Path"
   }
   Write-Host "Verified VAC installer signed by $($signature.SignerCertificate.Subject)."
}

function Register-AudioArrayTask {
   Remove-Item -LiteralPath $launcherPath -Force -ErrorAction SilentlyContinue
   $action = New-ScheduledTaskAction `
      -Execute $uiBinaryPath `
      -Argument "--tray"
   $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
   $principal = New-ScheduledTaskPrincipal `
      -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
      -LogonType Interactive `
      -RunLevel Limited
   $settings = New-ScheduledTaskSettingsSet `
      -AllowStartIfOnBatteries `
      -DontStopIfGoingOnBatteries `
      -ExecutionTimeLimit ([TimeSpan]::Zero) `
      -Priority 4 `
      -RestartCount 5 `
      -RestartInterval (New-TimeSpan -Minutes 1) `
      -MultipleInstances IgnoreNew
   Register-ScheduledTask `
      -TaskName $taskName `
      -Action $action `
      -Trigger $trigger `
      -Principal $principal `
      -Settings $settings `
      -Force | Out-Null
}

foreach ($requiredPath in @(
   $manifestPath,
   $uiManifestPath,
   $uiEntryPath,
   $exampleConfigPath,
   $endpointConfiguratorSource
)) {
   if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
      throw "AudioArray source is incomplete: $requiredPath"
   }
}

Assert-NativeBuildTools
New-Item -ItemType Directory -Path $applicationRoot, $buildRoot, $binaryRoot, $configRoot, $logRoot -Force |
   Out-Null

$sourceHash = Get-SourceHash -Root $SourceDirectory
$installedHash = if (Test-Path -LiteralPath $stampPath) {
   (Get-Content -LiteralPath $stampPath -Raw).Trim()
} else {
   ""
}
$rebuilt = $sourceHash -ne $installedHash -or
   -not (Test-Path -LiteralPath $binaryPath -PathType Leaf) -or
   -not (Test-Path -LiteralPath $uiBinaryPath -PathType Leaf)
if ($rebuilt) {
   $env:CARGO_TARGET_DIR = $buildRoot
   $builtBinary = Join-Path $buildRoot "release\audioarray.exe"
   $builtUiBinary = Join-Path $buildRoot "release\audioarray-ui.exe"
   # Cargo's timestamp checks across the WSL UNC boundary can incorrectly
   # retain a stale final executable even after recompiling the crate. Remove
   # only the disposable build artifact so a changed source hash must relink.
   Remove-Item -LiteralPath $builtBinary, $builtUiBinary -Force -ErrorAction SilentlyContinue
   Invoke-CargoReleaseBuild -CargoManifestPath $manifestPath
   if (-not (Test-Path -LiteralPath $builtBinary -PathType Leaf)) {
      throw "AudioArray build completed without producing $builtBinary."
   }
   Invoke-CargoReleaseBuild -CargoManifestPath $uiManifestPath
   if (-not (Test-Path -LiteralPath $builtUiBinary -PathType Leaf)) {
      throw "AudioArray interface build completed without producing $builtUiBinary."
   }
   Assert-AudioArrayApplicationPolicy -InterfacePath $builtUiBinary
   Stop-AudioArray
   $copied = $false
   for ($attempt = 1; $attempt -le 20; $attempt++) {
      try {
         Copy-Item -LiteralPath $builtBinary -Destination $binaryPath -Force
         Copy-Item -LiteralPath $builtUiBinary -Destination $uiBinaryPath -Force
         $copied = $true
         break
      } catch {
         if ($attempt -eq 20) {
            throw
         }
         Start-Sleep -Milliseconds 250
      }
   }
   if (-not $copied) {
      throw "An AudioArray executable remained locked after stopping its processes."
   }
   Set-Content -LiteralPath $stampPath -Value $sourceHash -Encoding ASCII
   Write-Host "Built and installed AudioArray engine and interface in $binaryRoot."
} else {
   Write-Host "AudioArray engine and interface are current."
}

$shortcutChanged = Install-AudioArrayShortcut
if ($shortcutChanged) {
   Write-Host "Updated the AudioArray Start-menu shortcut."
} else {
   Write-Host "AudioArray Start-menu shortcut is current."
}

$configChanged = -not (Test-FileEqual -Source $exampleConfigPath -Destination $configPath)
if ($configChanged) {
   Copy-Item -LiteralPath $exampleConfigPath -Destination $configPath -Force
   Write-Host "Updated AudioArray config at $configPath."
} else {
   Write-Host "AudioArray config is current."
}

if ($VacInstallerPath) {
   Assert-VacInstaller -Path $VacInstallerPath
   if (-not (Test-IsAdministrator)) {
      Write-Host "Opening the verified VAC installer; approve its UAC prompt and complete setup."
   }
   Start-Process -FilePath $VacInstallerPath
}

if (-not (Test-Path -LiteralPath $vacRegistryPath)) {
   Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
   Write-Warning @"
Virtual Audio Cable is not installed yet. Download the official VAC 4.71 trial
from $vacDownloadUrl, then purchase the `$30 Home license if it works. Keep the
licensed installer private. Rerun this script with:

  -VacInstallerPath 'C:\path\to\vac471.exe'

After installation, set "Cables" to 4 in VAC Control Panel and click Set/Restart.
AudioArray is built but will not auto-start until audioarray doctor passes.
"@
   if ($OpenVacDownload) {
      Start-Process $vacDownloadUrl
   }
   exit 0
}

$endpointNamesChanged = Assert-AudioArrayEndpointNames
$null = Set-AudioArraySpatialFormats
$null = Set-AudioArrayUnityGain
$taskChanged = -not (Test-AudioArrayTaskCurrent)
$restartRequired = $rebuilt -or $configChanged -or $endpointNamesChanged -or $taskChanged

$doctorOutput = & $binaryPath --config $configPath doctor 2>&1
$doctorExitCode = $LASTEXITCODE
$doctorOutput | Write-Host
if ($doctorExitCode -ne 0) {
   Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
   $controlPanel = Join-Path $env:ProgramFiles "Virtual Audio Cable\vcctlpan.exe"
   if (Test-Path -LiteralPath $controlPanel -PathType Leaf) {
      Start-Process -FilePath $controlPanel
   }
   Write-Warning "VAC is installed but the four-cable graph is incomplete. Set Cables to 4, restart the driver, then rerun dotctl apply."
   exit 0
}

if ($restartRequired) {
   Stop-AudioArray
   if ($taskChanged) {
      Register-AudioArrayTask
   }
   Start-ScheduledTask -TaskName $taskName
} elseif (-not (Test-AudioArrayRunning)) {
   Stop-AudioArray
   Start-ScheduledTask -TaskName $taskName
   Write-Host "AudioArray configuration was current; restarted its stopped supervisor and engine."
} else {
   Write-Host "AudioArray configuration and processes are current; no restart was needed."
}
if ($rebuilt) {
   # Smart App Control applies a stricter policy when PowerShell directly
   # creates an unknown locally-built GUI process. Ask the trusted Windows
   # shell to activate the already-installed binary, matching a Start-menu
   # launch without weakening system-wide application control.
   Start-Process `
      -FilePath (Join-Path $env:SystemRoot "explorer.exe") `
      -ArgumentList "`"$uiBinaryPath`""
}
Write-Host "AudioArray's tray supervisor and audio engine are running and will start at every interactive logon. Logs: $logPath"

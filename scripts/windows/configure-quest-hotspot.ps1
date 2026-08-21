param(
   [ValidateSet("Ensure", "Install", "Start", "Stop", "Status", "Optimize", "Remove")]
   [string]$Mode = "Ensure",
   [string]$Ssid = "Tracer-Quest-VR",
   [ValidateSet("Auto", "TwoPointFourGigahertz", "FiveGigahertz", "SixGigahertz")]
   [string]$Band = "FiveGigahertz",
   [ValidateSet("Wpa2", "Wpa3TransitionMode", "Wpa3")]
   [string]$Authentication = "Wpa2",
   [string]$Passphrase = ""
)

$ErrorActionPreference = "Stop"
$TaskName = "Dotfiles Quest VR Hotspot"
$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$VrRadioDescription = "Qualcomm FastConnect 7800 Wi-Fi 7 High Band Simultaneous (HBS) Network Adapter"
$VrRadioHardwareId = "PCI\VEN_17CB&DEV_1107&SUBSYS_E0F7105B"
$VrRadioDriverVersion = [version]"3.1.0.1647"
$VrRadioDriverUrl = "https://catalog.s.download.windowsupdate.com/d/msdownload/update/driver/drvs/2026/03/97313a84-6ee4-4750-9964-467fa1ee20c5_7b43725cd9ee65ff2cf46d9747fb4449df10cb79.cab"
$VrRadioDriverSha256 = "A214042F404A309238B226ACCB9E9CA371DB79EF6DD456FA8F0512AA76885960"

function Test-IsAdministrator {
   $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
   $principal = [Security.Principal.WindowsPrincipal]::new($identity)
   return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-VrRadioAdapters {
   return @(Get-NetAdapter -IncludeHidden | Where-Object {
      $_.InterfaceDescription -eq $VrRadioDescription -and
      $_.Status -ne "Not Present"
   })
}

function Get-VrRadio {
   $adapter = Get-VrRadioAdapters | Where-Object { $_.Name -eq "Wi-Fi" } | Select-Object -First 1
   if (-not $adapter) {
      throw "Could not find Tracer's primary '$VrRadioDescription' adapter named Wi-Fi."
   }
   return $adapter
}

function Install-VrRadioDriver {
   $radio = Get-VrRadio
   $installedVersion = [version]$radio.DriverVersion
   if ($installedVersion -ge $VrRadioDriverVersion) {
      Write-Host "Quest radio driver is current: $installedVersion."
      return
   }
   if (-not (Test-IsAdministrator)) {
      throw "Quest radio driver $installedVersion is older than $VrRadioDriverVersion; rerun the Windows integration elevated."
   }

   $workDirectory = Join-Path $env:TEMP "dotfiles-quest-radio-$([guid]::NewGuid().ToString('N'))"
   $cabPath = Join-Path $workDirectory "qualcomm-fastconnect-7800.cab"
   $expandedPath = Join-Path $workDirectory "driver"
   New-Item -ItemType Directory -Path $expandedPath -Force | Out-Null
   try {
      Write-Host "Downloading signed Qualcomm FastConnect driver $VrRadioDriverVersion from Microsoft Update Catalog..."
      Invoke-WebRequest -UseBasicParsing -Uri $VrRadioDriverUrl -OutFile $cabPath
      $actualHash = (Get-FileHash -LiteralPath $cabPath -Algorithm SHA256).Hash
      if ($actualHash -ne $VrRadioDriverSha256) {
         throw "Quest radio driver checksum mismatch: expected $VrRadioDriverSha256, received $actualHash."
      }

      & "$env:SystemRoot\System32\expand.exe" $cabPath -F:* $expandedPath | Out-Null
      if ($LASTEXITCODE -ne 0) {
         throw "Could not expand the Quest radio driver CAB (exit code $LASTEXITCODE)."
      }
      $inf = Get-ChildItem -LiteralPath $expandedPath -Filter "qcwlan64.inf" | Select-Object -First 1
      $catalog = Get-ChildItem -LiteralPath $expandedPath -Filter "qcwlan64.cat" | Select-Object -First 1
      if (-not $inf -or -not $catalog) {
         throw "The Quest radio driver package is missing qcwlan64.inf or qcwlan64.cat."
      }
      if (-not (Select-String -LiteralPath $inf.FullName -SimpleMatch $VrRadioHardwareId -Quiet)) {
         throw "The Quest radio driver does not declare support for $VrRadioHardwareId."
      }
      $signature = Get-AuthenticodeSignature -LiteralPath $catalog.FullName
      if (
         $signature.Status -ne "Valid" -or
         $signature.SignerCertificate.Subject -notmatch "Microsoft Windows Hardware Compatibility Publisher"
      ) {
         throw "The Quest radio driver catalog does not have a valid Microsoft hardware signature."
      }

      & "$env:SystemRoot\System32\pnputil.exe" /add-driver $inf.FullName /install
      if ($LASTEXITCODE -ne 0) {
         throw "PnPUtil could not install the Quest radio driver (exit code $LASTEXITCODE)."
      }
      Start-Sleep -Seconds 2
      $newVersion = [version](Get-VrRadio).DriverVersion
      if ($newVersion -lt $VrRadioDriverVersion) {
         throw "Quest radio still reports driver $newVersion after installing $VrRadioDriverVersion."
      }
      Write-Host "Updated the Quest radio driver from $installedVersion to $newVersion."
   } finally {
      Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
   }
}

function Set-VrRadioPerformancePolicy {
   $isAdministrator = Test-IsAdministrator
   $changedAdapters = @()
   foreach ($radio in Get-VrRadioAdapters) {
      try {
         $power = Get-NetAdapterPowerManagement -Name $radio.Name -ErrorAction Stop
         $roaming = Get-NetAdapterAdvancedProperty `
            -Name $radio.Name `
            -RegistryKeyword "roamPolicy" `
            -ErrorAction Stop
         $idleRestriction = Get-NetAdapterAdvancedProperty `
            -Name $radio.Name `
            -RegistryKeyword "*IdleRestriction" `
            -ErrorAction Stop
      } catch {
         continue
      }

      $radioChanged = $false
      if ($power.AllowComputerToTurnOffDevice.ToString() -ne "Disabled") {
         if (-not $isAdministrator) {
            throw "Quest radio power policy needs repair; rerun the Windows integration elevated."
         }
         $power.AllowComputerToTurnOffDevice = "Disabled"
         $power | Set-NetAdapterPowerManagement -NoRestart
         $radioChanged = $true
      }
      if ($idleRestriction.RegistryValue[0].ToString() -ne "1") {
         if (-not $isAdministrator) {
            throw "Quest radio idle policy needs repair; rerun the Windows integration elevated."
         }
         Set-NetAdapterAdvancedProperty `
            -Name $radio.Name `
            -RegistryKeyword "*IdleRestriction" `
            -RegistryValue 1 `
            -NoRestart
         $radioChanged = $true
      }
      if ($roaming.RegistryValue[0].ToString() -ne "1") {
         if (-not $isAdministrator) {
            throw "Quest radio roaming policy needs repair; rerun the Windows integration elevated."
         }
         Set-NetAdapterAdvancedProperty `
            -Name $radio.Name `
            -RegistryKeyword "roamPolicy" `
            -RegistryValue 1 `
            -NoRestart
         $radioChanged = $true
      }
      if ($radioChanged) {
         $changedAdapters += $radio.Name
      }
   }

   if ($changedAdapters.Count -gt 0) {
      # Restarting Qualcomm's derived HBS interfaces can leave them disabled;
      # cycling the primary adapter reinitializes the shared physical radio.
      Restart-NetAdapter -Name (Get-VrRadio).Name -Confirm:$false
      Write-Host "Applied the low-latency Quest radio power and roaming policy."
   } else {
      Write-Host "Quest radio power and roaming policy is current."
   }
}

function Show-VrRadioStatus {
   foreach ($radio in Get-VrRadioAdapters) {
      try {
         $power = Get-NetAdapterPowerManagement -Name $radio.Name -ErrorAction Stop
         $roaming = Get-NetAdapterAdvancedProperty `
            -Name $radio.Name `
            -RegistryKeyword "roamPolicy" `
            -ErrorAction Stop
         $idleRestriction = Get-NetAdapterAdvancedProperty `
            -Name $radio.Name `
            -RegistryKeyword "*IdleRestriction" `
            -ErrorAction Stop
      } catch {
         continue
      }
      [pscustomobject]@{
         Radio = $radio.Name
         Status = $radio.Status
         DriverVersion = $radio.DriverVersion
         DriverDate = $radio.DriverDate
         AllowPowerOff = $power.AllowComputerToTurnOffDevice
         SelectiveSuspend = $power.SelectiveSuspend
         IdlePowerDownRestriction = $idleRestriction.DisplayValue
         RoamingAggressiveness = $roaming.DisplayValue
      } | Format-List
   }
}

function Initialize-TetheringApi {
   Add-Type -AssemblyName System.Runtime.WindowsRuntime
   [void][Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
   [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
   [void][Windows.Networking.NetworkOperators.TetheringWiFiBand, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
   [void][Windows.Networking.NetworkOperators.TetheringWiFiAuthenticationKind, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
}

function Get-TetheringContext {
   $profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
   if (-not $profile -or $profile.GetNetworkConnectivityLevel().ToString() -ne "InternetAccess") {
      return $null
   }

   try {
      $manager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
   } catch [System.Exception] {
      # Immediately after a radio or uplink restart, NetworkInformation can
      # advertise InternetAccess before the tethering service has registered
      # the profile. Treat that short race like any other not-ready state.
      return $null
   }
   return [pscustomobject]@{
      Profile = $profile
      Manager = $manager
   }
}

function Wait-TetheringState {
   param(
      [Parameter(Mandatory = $true)]$Manager,
      [Parameter(Mandatory = $true)][string]$DesiredState,
      [int]$TimeoutSeconds = 30
   )

   $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
   do {
      if ($Manager.TetheringOperationalState.ToString() -eq $DesiredState) {
         return
      }
      Start-Sleep -Milliseconds 200
   } while ([DateTime]::UtcNow -lt $deadline)

   throw "Mobile Hotspot did not reach $DesiredState within $TimeoutSeconds seconds; current state is $($Manager.TetheringOperationalState)."
}

function Stop-Hotspot {
   param([Parameter(Mandatory = $true)]$Manager)

   if ($Manager.TetheringOperationalState.ToString() -eq "Off") {
      return
   }
   $stopOperation = $Manager.StopTetheringAsync()
   Wait-TetheringState -Manager $Manager -DesiredState "Off"
   [GC]::KeepAlive($stopOperation)
}

function Set-HotspotConfiguration {
   param([Parameter(Mandatory = $true)]$Manager)

   $configuration = $Manager.GetCurrentAccessPointConfiguration()
   $desiredPassphrase = if ($Passphrase) { $Passphrase } else { $configuration.Passphrase }
   if ([string]::IsNullOrWhiteSpace($desiredPassphrase)) {
      throw "Windows has no saved Mobile Hotspot passphrase. Supply -Passphrase once; it will remain machine-local."
   }

   $desiredBand = [Windows.Networking.NetworkOperators.TetheringWiFiBand]::$Band
   $desiredAuthentication = [Windows.Networking.NetworkOperators.TetheringWiFiAuthenticationKind]::$Authentication
   $configurationChanged =
      $configuration.Ssid -ne $Ssid -or
      $configuration.Passphrase -ne $desiredPassphrase -or
      $configuration.Band -ne $desiredBand -or
      $configuration.AuthenticationKind -ne $desiredAuthentication

   if (-not $configurationChanged) {
      return
   }

   Stop-Hotspot -Manager $Manager
   $configuration.Ssid = $Ssid
   $configuration.Passphrase = $desiredPassphrase
   $configuration.Band = $desiredBand
   $configuration.AuthenticationKind = $desiredAuthentication
   $configureOperation = $Manager.ConfigureAccessPointAsync($configuration)

   $deadline = [DateTime]::UtcNow.AddSeconds(30)
   do {
      Start-Sleep -Milliseconds 200
      $current = $Manager.GetCurrentAccessPointConfiguration()
      if (
         $current.Ssid -eq $Ssid -and
         $current.Band -eq $desiredBand -and
         $current.AuthenticationKind -eq $desiredAuthentication
      ) {
         [GC]::KeepAlive($configureOperation)
         return
      }
   } while ([DateTime]::UtcNow -lt $deadline)

   throw "Windows did not persist the requested Mobile Hotspot configuration."
}

function Start-Hotspot {
   Initialize-TetheringApi
   [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::DisableNoConnectionsTimeout()

   $context = $null
   for ($attempt = 1; $attempt -le 12; $attempt++) {
      $context = Get-TetheringContext
      if ($context) {
         break
      }
      Start-Sleep -Seconds 5
   }
   if (-not $context) {
      throw "No internet-connected Windows profile became available within one minute."
   }

   Set-HotspotConfiguration -Manager $context.Manager
   if ($context.Manager.TetheringOperationalState.ToString() -ne "On") {
      $startOperation = $context.Manager.StartTetheringAsync()
      Wait-TetheringState -Manager $context.Manager -DesiredState "On"
      [GC]::KeepAlive($startOperation)
   }

   $configuration = $context.Manager.GetCurrentAccessPointConfiguration()
   Write-Host "Quest hotspot is on: $($configuration.Ssid), $($configuration.Band), upstream $($context.Profile.ProfileName)."
}

function Show-HotspotStatus {
   Show-VrRadioStatus
   Initialize-TetheringApi
   $context = Get-TetheringContext
   if (-not $context) {
      Write-Host "No internet-connected Windows profile is available."
      return
   }
   $configuration = $context.Manager.GetCurrentAccessPointConfiguration()
   [pscustomobject]@{
      Upstream = $context.Profile.ProfileName
      State = $context.Manager.TetheringOperationalState
      Ssid = $configuration.Ssid
      Band = $configuration.Band
      Authentication = $configuration.AuthenticationKind
      Clients = $context.Manager.ClientCount
   } | Format-List
}

function New-EventTrigger {
   $subscription = @"
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">
    <Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[EventID=10000]]</Select>
  </Query>
  <Query Id="1" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select>
  </Query>
</QueryList>
"@
   $trigger = New-CimInstance `
      -Namespace "Root/Microsoft/Windows/TaskScheduler" `
      -ClassName "MSFT_TaskEventTrigger" `
      -ClientOnly `
      -Property @{
         Enabled = $true
         Delay = "PT5S"
         Subscription = $subscription
      }
   # Client-only CIM instances do not inherit their parent task-trigger type
   # names automatically, but ScheduledTasks validates those names strictly.
   $trigger.PSObject.TypeNames.Insert(
      1,
      "Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/TaskScheduler/MSFT_TaskTrigger"
   )
   $trigger.PSObject.TypeNames.Insert(
      3,
      "Microsoft.Management.Infrastructure.CimInstance#MSFT_TaskTrigger"
   )
   return $trigger
}

function Get-HotspotTaskActionArguments {
   return @(
      "-NoLogo",
      "-NoProfile",
      "-WindowStyle", "Hidden",
      "-ExecutionPolicy", "Bypass",
      "-File", ('"{0}"' -f $PSCommandPath),
      "-Mode", "Start",
      "-Ssid", ('"{0}"' -f $Ssid),
      "-Band", $Band,
      "-Authentication", $Authentication
   ) -join " "
}

function Test-HotspotTaskCurrent {
   param([Parameter(Mandatory = $true)][string]$ActionArguments)

   $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
   return [bool](
      $task -and
      $task.Actions.Count -eq 1 -and
      $task.Actions[0].Execute -ieq $PowerShell -and
      $task.Actions[0].Arguments -eq $ActionArguments -and
      $task.Triggers.Count -eq 2 -and
      @($task.Triggers | Where-Object {
         $_.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger"
      }).Count -eq 1 -and
      @($task.Triggers | Where-Object {
         $_.CimClass.CimClassName -eq "MSFT_TaskEventTrigger"
      }).Count -eq 1 -and
      $task.Principal.RunLevel.ToString() -eq "Limited" -and
      $task.Settings.ExecutionTimeLimit -eq "PT2M" -and
      $task.Settings.MultipleInstances.ToString() -eq "IgnoreNew" -and
      $task.Settings.StartWhenAvailable -eq $true
   )
}

function Install-HotspotTask {
   Install-VrRadioDriver
   Set-VrRadioPerformancePolicy

   $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
   $actionArguments = Get-HotspotTaskActionArguments
   if (-not (Test-HotspotTaskCurrent -ActionArguments $actionArguments)) {
      $action = New-ScheduledTaskAction -Execute $PowerShell -Argument $actionArguments
      $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
      $eventTrigger = New-EventTrigger
      $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
      $settings = New-ScheduledTaskSettingsSet `
         -AllowStartIfOnBatteries `
         -DontStopIfGoingOnBatteries `
         -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2)) `
         -MultipleInstances IgnoreNew `
         -StartWhenAvailable

      Register-ScheduledTask `
         -TaskName $TaskName `
         -Description "Keep Tracer's dedicated 5 GHz Quest VR Mobile Hotspot available without polling." `
         -Action $action `
         -Trigger @($logonTrigger, $eventTrigger) `
         -Principal $principal `
         -Settings $settings `
         -Force | Out-Null
      Write-Host "Installed the event-driven '$TaskName' task."
   } else {
      Write-Host "'$TaskName' is current."
   }
   Start-Hotspot
}

function Remove-HotspotTask {
   Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
   Write-Host "Removed '$TaskName'."
}

switch ($Mode) {
   "Ensure" { Install-HotspotTask }
   "Install" { Install-HotspotTask }
   "Optimize" {
      Install-VrRadioDriver
      Set-VrRadioPerformancePolicy
      Start-Hotspot
   }
   "Start" { Start-Hotspot }
   "Stop" {
      Initialize-TetheringApi
      $context = Get-TetheringContext
      if ($context) {
         Stop-Hotspot -Manager $context.Manager
      }
   }
   "Status" { Show-HotspotStatus }
   "Remove" { Remove-HotspotTask }
}

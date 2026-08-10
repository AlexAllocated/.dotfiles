param(
   [ValidateSet("Ensure", "Install", "Start", "Stop", "Status", "Remove")]
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

   $manager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
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

function Install-HotspotTask {
   $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
   $actionArguments = @(
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
   Start-Hotspot
   Write-Host "Installed the event-driven '$TaskName' task."
}

function Remove-HotspotTask {
   Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
   Write-Host "Removed '$TaskName'."
}

switch ($Mode) {
   "Ensure" { Install-HotspotTask }
   "Install" { Install-HotspotTask }
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

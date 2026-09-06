param(
   [string]$LogPath = "",

   [switch]$EnsureCableCapacity
)

$ErrorActionPreference = "Stop"

trap {
   if ($LogPath) {
      $_ | Out-String | Set-Content -LiteralPath $LogPath -Encoding UTF8
   }
   Write-Error $_
   exit 1
}

# VAC documents both registry locations in its installed configure.htm and
# setvars.cmd. Increasing capacity preserves every existing per-cable setting.
# Keep this separate from naming so installation can preflight the driver before
# replacing a working engine with one that requires additional endpoints.
if ($EnsureCableCapacity) {
   $softwareKey = "HKLM:\SOFTWARE\EuMus Design\Virtual Audio Cable\4"
   if (-not (Test-Path -LiteralPath $softwareKey)) {
      throw "Install Virtual Audio Cable before provisioning AudioArray cables."
   }
   $devices = @(Get-PnpDevice -PresentOnly -Class MEDIA | Where-Object FriendlyName -eq "Virtual Audio Cable")
   if ($devices.Count -ne 1) {
      throw "Expected exactly one installed Virtual Audio Cable driver; found $($devices.Count)."
   }
   $device = $devices[0]
   $service = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName DEVPKEY_Device_Service).Data
   if ($service -notmatch '^VirtualAudioCable_[a-fA-F0-9]+$') {
      throw "Unexpected Virtual Audio Cable service: $service"
   }
   $driverKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$service\Parameters"
   if (-not (Test-Path -LiteralPath $driverKey)) {
      throw "VAC boot-time parameter key is missing: $driverKey"
   }
   function Test-VacCapacity {
      $found = @{}
      foreach ($direction in @("Render", "Capture")) {
         $root = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$direction"
         foreach ($endpoint in Get-ChildItem -LiteralPath $root) {
            if ((Get-ItemProperty -LiteralPath $endpoint.PSPath).DeviceState -ne 1) { continue }
            $properties = Get-ItemProperty -LiteralPath (Join-Path $endpoint.PSPath "Properties")
            if ($properties.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6' -ne "Virtual Audio Cable") { continue }
            if ($properties.'{233164c8-1b2c-4c7d-bc68-b671687a2567},1' -match '\\wave(?<Cable>[1-7])_[rc]_rt') {
               $found["$direction/$($Matches.Cable)"] = $true
            }
         }
      }
      return $found.Count -eq 14
   }
   $oldSoftwareCount = [int](Get-ItemProperty -LiteralPath $softwareKey).'Number of cables'
   $oldDriverCount = [int](Get-ItemProperty -LiteralPath $driverKey).'Number of cables'
   if ($oldSoftwareCount -ge 7 -and $oldDriverCount -ge 7 -and (Test-VacCapacity)) {
      if ($LogPath) { "Seven active VAC cable pairs verified; no elevation or restart needed." | Set-Content -LiteralPath $LogPath -Encoding UTF8 }
      Write-Host "VAC already exposes all seven AudioArray cables; no elevation or restart needed."
      exit 0
   }
   $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
   if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
      if (-not $LogPath) { $LogPath = Join-Path $env:TEMP "audioarray-vac-capacity.log" }
      Write-Host "VAC needs seven cables. Approve the Windows UAC prompt; audio will briefly restart."
      $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
         -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList @(
            "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"",
            "-EnsureCableCapacity", "-LogPath", "`"$LogPath`""
         )
      $null = $process.Handle
      $process.WaitForExit()
      $process.Refresh()
      if ($process.ExitCode -ne 0) {
         $details = if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath -Raw } else { "No driver log was produced." }
         throw "VAC capacity reconciliation failed ($($process.ExitCode)): $details"
      }
      if (-not (Test-VacCapacity)) { throw "VAC restart did not publish all seven cables. No reboot was attempted." }
      Write-Host "VAC now exposes seven playback and seven recording endpoints."
      exit 0
   }

   $binaryRoot = Join-Path $env:LOCALAPPDATA "AudioArray\bin"
   $processes = @(Get-Process audioarray,audioarray-ui -ErrorAction SilentlyContinue | Where-Object {
      $_.Path -in @((Join-Path $binaryRoot "audioarray.exe"), (Join-Path $binaryRoot "audioarray-ui.exe"))
   })
   $task = Get-ScheduledTask -TaskName AudioArray -ErrorAction SilentlyContinue
   $resumeArray = $processes.Count -gt 0 -or ($task -and $task.State -eq "Running")
   if ($resumeArray -and -not $task) { throw "Cannot safely restore AudioArray: its scheduled task is missing." }
   $audio = Get-Service Audiosrv
   $resumeAudio = $audio.Status -eq "Running"
   $dependents = @($audio.DependentServices | Where-Object Status -eq "Running" | Select-Object -ExpandProperty Name)
   $desiredCount = [Math]::Max(7, [Math]::Max($oldSoftwareCount, $oldDriverCount))
   $failure = $null
   try {
      if ($resumeArray) {
         Stop-ScheduledTask -TaskName AudioArray
         $processes | Stop-Process -Force -ErrorAction SilentlyContinue
      }
      if ($resumeAudio) { Stop-Service Audiosrv -Force }
      foreach ($key in @($softwareKey, $driverKey)) {
         New-ItemProperty -LiteralPath $key -Name "Number of cables" -Value $desiredCount -PropertyType DWord -Force | Out-Null
      }
      $restart = Start-Process -FilePath "$env:SystemRoot\System32\pnputil.exe" `
         -ArgumentList @("/restart-device", "`"$($device.InstanceId)`"") -NoNewWindow -PassThru
      $null = $restart.Handle
      $restart.WaitForExit()
      $restart.Refresh()
      if ($restart.ExitCode -ne 0) {
         throw "VAC device restart returned $($restart.ExitCode). A manual reboot may be required; none was requested."
      }
   } catch {
      $failure = $_
      New-ItemProperty -LiteralPath $softwareKey -Name "Number of cables" -Value $oldSoftwareCount -PropertyType DWord -Force | Out-Null
      New-ItemProperty -LiteralPath $driverKey -Name "Number of cables" -Value $oldDriverCount -PropertyType DWord -Force | Out-Null
   } finally {
      try {
         if ($resumeAudio) { Start-Service Audiosrv }
         foreach ($name in $dependents) { Start-Service -Name $name }
      } finally {
         if ($resumeArray) { Start-ScheduledTask -TaskName AudioArray }
      }
   }
   if ($failure) { throw $failure }
   $ready = $false
   # Endpoint Builder can publish a new cable well after Audiosrv is running.
   for ($attempt = 0; $attempt -lt 90; $attempt++) {
      if (Test-VacCapacity) { $ready = $true; break }
      Start-Sleep -Milliseconds 500
   }
   if (-not $ready) { throw "VAC restart completed but seven active cable pairs did not appear. Existing AudioArray was restarted; no reboot was attempted." }
   if ($LogPath) { "VAC capacity is $desiredCount; seven active playback/recording pairs verified. Existing AudioArray resumed." | Set-Content -LiteralPath $LogPath -Encoding UTF8 }
   Write-Host "VAC capacity reconciled; existing AudioArray resumed."
   exit 0
}

if (-not ("AudioArray.EndpointPolicy" -as [type])) {
   Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace AudioArray {
   [StructLayout(LayoutKind.Sequential)]
   internal struct PropertyKey {
      internal Guid FormatId;
      internal int PropertyId;
   }

   [StructLayout(LayoutKind.Explicit)]
   internal struct PropVariant {
      [FieldOffset(0)] internal ushort VariantType;
      [FieldOffset(8)] internal IntPtr PointerValue;
   }

   [ComImport]
   [Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
   internal class PolicyConfigClientCom { }

   [ComImport]
   [Guid("f8679f50-850a-41cf-9c72-430f290290c8")]
   [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
   internal interface IPolicyConfig {
      [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr format);
      [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.Bool)] bool isDefault, IntPtr format);
      [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id);
      [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr endpointFormat, IntPtr mixFormat);
      [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.Bool)] bool isDefault, IntPtr defaultPeriod, IntPtr minimumPeriod);
      [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr period);
      [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
      [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
      [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.Bool)] bool effectsStore, IntPtr key, IntPtr value);
      [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.Bool)] bool effectsStore, IntPtr key, IntPtr value);
      [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
      [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.Bool)] bool visible);
   }

   public static class EndpointPolicy {
      public static void SetDeviceDescription(string endpointId, string description) {
         PropertyKey key = new PropertyKey {
            FormatId = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"),
            PropertyId = 2
         };
         PropVariant value = new PropVariant {
            VariantType = 31,
            PointerValue = Marshal.StringToCoTaskMemUni(description)
         };
         IntPtr keyPointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(PropertyKey)));
         IntPtr valuePointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(PropVariant)));
         IPolicyConfig policy = null;
         try {
            Marshal.StructureToPtr(key, keyPointer, false);
            Marshal.StructureToPtr(value, valuePointer, false);
            policy = (IPolicyConfig)(object)new PolicyConfigClientCom();
            int result = policy.SetPropertyValue(endpointId, false, keyPointer, valuePointer);
            if (result != 0) {
               Marshal.ThrowExceptionForHR(result);
            }
         } finally {
            if (policy != null && Marshal.IsComObject(policy)) {
               Marshal.ReleaseComObject(policy);
            }
            Marshal.FreeHGlobal(keyPointer);
            Marshal.FreeHGlobal(valuePointer);
            Marshal.FreeCoTaskMem(value.PointerValue);
         }
      }
   }
}
"@
}

$audioRoot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio"
$friendlyNameProperty = "{a45c254e-df1c-4efd-8020-67d146a850e0},2"
$deviceNameProperty = "{b3f8fa53-0004-438e-9003-51a46e139bfc},6"
$backingPathProperty = "{233164c8-1b2c-4c7d-bc68-b671687a2567},1"
$names = @{
   1 = "AudioArray Game"
   2 = "AudioArray Comms Audio"
   3 = "AudioArray Media"
   4 = "AudioArray Clean Mic"
   5 = "AudioArray AI Audio"
   6 = "AudioArray AI Mic"
   7 = "AudioArray Comms Mic"
}
$changed = $false
$found = @{}

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
      if ($currentName -notmatch '^Line [1-7]$' -and $currentName -notin $names.Values -and $currentName -notin @("AudioArray Music", "AudioArray ChatGPT", "AudioArray Comms", "AudioArray Discord Send", "AudioArray Comms In", "AudioArray Comms Send", "AudioArray ChatGPT Out", "AudioArray ChatGPT In")) {
         continue
      }
      $backingPath = [string]$properties.$backingPathProperty
      if ($backingPath -notmatch '\\wave(?<Cable>[1-7])_[rc]_rt') {
         continue
      }
      $cable = [int]$Matches.Cable
      $found["$direction/$cable"] = $true
      $desiredName = $names[$cable]
      if ($properties.$friendlyNameProperty -ne $desiredName) {
         $endpointPrefix = if ($direction -eq "Render") {
            "{0.0.0.00000000}"
         } else {
            "{0.0.1.00000000}"
         }
         $endpointId = "$endpointPrefix.$($endpoint.PSChildName)"
         [AudioArray.EndpointPolicy]::SetDeviceDescription($endpointId, $desiredName)
         Write-Host "Renamed VAC cable $cable $direction endpoint to $desiredName."
         $changed = $true
      }
   }
}

$missing = foreach ($direction in @("Render", "Capture")) {
   foreach ($cable in 1..7) {
      if (-not $found.ContainsKey("$direction/$cable")) {
         "$direction cable $cable"
      }
   }
}
if ($missing) {
   throw "Could not identify every AudioArray VAC endpoint: $($missing -join ', ')."
}

if ($changed) {
   Start-Sleep -Seconds 2
   Write-Host "Windows Audio published the new AudioArray endpoint names."
} else {
   Write-Host "AudioArray endpoint names are current."
}

if ($LogPath) {
   "AudioArray endpoint naming completed successfully." |
      Set-Content -LiteralPath $LogPath -Encoding UTF8
}

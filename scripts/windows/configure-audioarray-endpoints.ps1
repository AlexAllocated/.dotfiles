param(
   [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"

trap {
   if ($LogPath) {
      $_ | Out-String | Set-Content -LiteralPath $LogPath -Encoding UTF8
   }
   Write-Error $_
   exit 1
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
   2 = "AudioArray Comms"
   3 = "AudioArray Music"
   4 = "AudioArray Clean Mic"
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
      if ($currentName -notmatch '^Line [1-4]$' -and $currentName -notin $names.Values) {
         continue
      }
      $backingPath = [string]$properties.$backingPathProperty
      if ($backingPath -notmatch '\\wave(?<Cable>[1-4])_[rc]_rt') {
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
   foreach ($cable in 1..4) {
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

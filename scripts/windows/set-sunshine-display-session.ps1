param(
	[ValidateSet("Start", "Stop")]
	[string]$Mode = "Start",
	[int]$Width = 2732,
	[int]$Height = 2048,
	[int]$RefreshRate = 120
)

$ErrorActionPreference = "Stop"

if (-not ([System.Management.Automation.PSTypeName]"Dotfiles.DisplayMode").Type) {
	Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Dotfiles {
   public static class DisplayMode {
      private const int ENUM_CURRENT_SETTINGS = -1;
      private const int CDS_UPDATEREGISTRY = 0x00000001;
      private const int CDS_TEST = 0x00000002;
      private const int DISP_CHANGE_SUCCESSFUL = 0;
      private const int DM_PELSWIDTH = 0x00080000;
      private const int DM_PELSHEIGHT = 0x00100000;
      private const int DM_DISPLAYFREQUENCY = 0x00400000;

      [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
      private struct DISPLAY_DEVICE {
         public int cb;
         [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
         public string DeviceName;
         [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
         public string DeviceString;
         public int StateFlags;
         [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
         public string DeviceID;
         [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
         public string DeviceKey;
      }

      [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
      private struct DEVMODE {
         [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
         public string dmDeviceName;
         public short dmSpecVersion;
         public short dmDriverVersion;
         public short dmSize;
         public short dmDriverExtra;
         public int dmFields;
         public int dmPositionX;
         public int dmPositionY;
         public int dmDisplayOrientation;
         public int dmDisplayFixedOutput;
         public short dmColor;
         public short dmDuplex;
         public short dmYResolution;
         public short dmTTOption;
         public short dmCollate;
         [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
         public string dmFormName;
         public short dmLogPixels;
         public int dmBitsPerPel;
         public int dmPelsWidth;
         public int dmPelsHeight;
         public int dmDisplayFlags;
         public int dmDisplayFrequency;
         public int dmICMMethod;
         public int dmICMIntent;
         public int dmMediaType;
         public int dmDitherType;
         public int dmReserved1;
         public int dmReserved2;
         public int dmPanningWidth;
         public int dmPanningHeight;
      }

      [DllImport("user32.dll", CharSet = CharSet.Unicode)]
      private static extern bool EnumDisplayDevices(
         string lpDevice,
         int iDevNum,
         ref DISPLAY_DEVICE lpDisplayDevice,
         int dwFlags
      );

      [DllImport("user32.dll", CharSet = CharSet.Unicode)]
      private static extern bool EnumDisplaySettings(
         string lpszDeviceName,
         int iModeNum,
         ref DEVMODE lpDevMode
      );

      [DllImport("user32.dll", CharSet = CharSet.Unicode)]
      private static extern int ChangeDisplaySettingsEx(
         string lpszDeviceName,
         ref DEVMODE lpDevMode,
         IntPtr hwnd,
         int dwflags,
         IntPtr lParam
      );

      private static string FindVirtualDisplayName() {
         for (var adapterIndex = 0; ; adapterIndex++) {
            var adapter = new DISPLAY_DEVICE();
            adapter.cb = Marshal.SizeOf(adapter);
            if (!EnumDisplayDevices(null, adapterIndex, ref adapter, 0)) {
               break;
            }

            for (var monitorIndex = 0; ; monitorIndex++) {
               var monitor = new DISPLAY_DEVICE();
               monitor.cb = Marshal.SizeOf(monitor);
               if (!EnumDisplayDevices(adapter.DeviceName, monitorIndex, ref monitor, 0)) {
                  break;
               }
               var id = monitor.DeviceID ?? "";
               var name = monitor.DeviceString ?? "";
               if (
                  id.IndexOf("MTT1337", StringComparison.OrdinalIgnoreCase) >= 0 ||
                  name.IndexOf("VDD by MTT", StringComparison.OrdinalIgnoreCase) >= 0
               ) {
                  return adapter.DeviceName;
               }
            }
         }
         throw new InvalidOperationException("Could not find the VDD by MTT display output.");
      }

      public static string Apply(int width, int height, int refreshRate) {
         var deviceName = FindVirtualDisplayName();
         var exactModeExists = false;
         for (var modeIndex = 0; ; modeIndex++) {
            var candidate = new DEVMODE();
            candidate.dmSize = (short)Marshal.SizeOf(candidate);
            if (!EnumDisplaySettings(deviceName, modeIndex, ref candidate)) {
               break;
            }
            if (
               candidate.dmPelsWidth == width &&
               candidate.dmPelsHeight == height &&
               candidate.dmDisplayFrequency == refreshRate
            ) {
               exactModeExists = true;
               break;
            }
         }
         if (!exactModeExists) {
            throw new InvalidOperationException(
               String.Format("{0}x{1} at {2} Hz is not advertised by {3}.", width, height, refreshRate, deviceName)
            );
         }

         var mode = new DEVMODE();
         mode.dmSize = (short)Marshal.SizeOf(mode);
         if (!EnumDisplaySettings(deviceName, ENUM_CURRENT_SETTINGS, ref mode)) {
            throw new InvalidOperationException("Could not read the current VDD display mode.");
         }
         mode.dmPelsWidth = width;
         mode.dmPelsHeight = height;
         mode.dmDisplayFrequency = refreshRate;
         mode.dmFields |= DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;

         var testResult = ChangeDisplaySettingsEx(deviceName, ref mode, IntPtr.Zero, CDS_TEST, IntPtr.Zero);
         if (testResult != DISP_CHANGE_SUCCESSFUL) {
            throw new InvalidOperationException("Windows rejected the requested VDD mode during validation: " + testResult);
         }
         var applyResult = ChangeDisplaySettingsEx(deviceName, ref mode, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
         if (applyResult != DISP_CHANGE_SUCCESSFUL) {
            throw new InvalidOperationException("Windows rejected the requested VDD mode: " + applyResult);
         }

         return String.Format("{0} is now {1}x{2} at {3} Hz.", deviceName, width, height, refreshRate);
      }
   }
}
'@
}

if ($Mode -eq "Stop") {
	Write-Host "Sunshine's display manager will restore the pre-stream topology."
	exit 0
}

& "$env:WINDIR\System32\DisplaySwitch.exe" /external
Start-Sleep -Seconds 2
Write-Host ([Dotfiles.DisplayMode]::Apply($Width, $Height, $RefreshRate))

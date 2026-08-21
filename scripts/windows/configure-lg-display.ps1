param(
	[int]$Width = 3440,
	[int]$Height = 1440,
	[int]$RefreshRate = 160
)

$ErrorActionPreference = "Stop"

if (-not ([System.Management.Automation.PSTypeName]"Dotfiles.LgDisplayMode").Type) {
	Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Dotfiles {
   public static class LgDisplayMode {
      private const int ENUM_CURRENT_SETTINGS = -1;
      private const int CDS_UPDATEREGISTRY = 0x00000001;
      private const int CDS_TEST = 0x00000002;
      private const int DISP_CHANGE_SUCCESSFUL = 0;
      private const int DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x00000001;
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

      private static string FindLgDisplayName(out bool attached) {
         attached = false;
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
                  id.IndexOf("GSM774B", StringComparison.OrdinalIgnoreCase) >= 0 ||
                  name.IndexOf("LG ULTRAGEAR", StringComparison.OrdinalIgnoreCase) >= 0
               ) {
                  attached = (adapter.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;
                  return adapter.DeviceName;
               }
            }
         }
         return null;
      }

      public static string Ensure(int width, int height, int refreshRate) {
         bool attached;
         var deviceName = FindLgDisplayName(out attached);
         if (deviceName == null) {
            return "LG UltraGear is not connected; deferring its display-mode reconciliation.";
         }
         if (!attached) {
            return "LG UltraGear is connected but inactive; deferring its display-mode reconciliation.";
         }

         var current = new DEVMODE();
         current.dmSize = (short)Marshal.SizeOf(current);
         if (!EnumDisplaySettings(deviceName, ENUM_CURRENT_SETTINGS, ref current)) {
            throw new InvalidOperationException("Could not read the current LG UltraGear display mode.");
         }
         if (
            current.dmPelsWidth == width &&
            current.dmPelsHeight == height &&
            current.dmDisplayFrequency == refreshRate
         ) {
            return String.Format("LG UltraGear is already {0}x{1} at {2} Hz.", width, height, refreshRate);
         }

         DEVMODE selected = new DEVMODE();
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
               selected = candidate;
               exactModeExists = true;
               break;
            }
         }
         if (!exactModeExists) {
            throw new InvalidOperationException(
               String.Format("{0}x{1} at {2} Hz is not advertised by the LG UltraGear.", width, height, refreshRate)
            );
         }

         selected.dmFields |= DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
         var testResult = ChangeDisplaySettingsEx(deviceName, ref selected, IntPtr.Zero, CDS_TEST, IntPtr.Zero);
         if (testResult != DISP_CHANGE_SUCCESSFUL) {
            throw new InvalidOperationException("Windows rejected the requested LG mode during validation: " + testResult);
         }
         var applyResult = ChangeDisplaySettingsEx(
            deviceName,
            ref selected,
            IntPtr.Zero,
            CDS_UPDATEREGISTRY,
            IntPtr.Zero
         );
         if (applyResult != DISP_CHANGE_SUCCESSFUL) {
            throw new InvalidOperationException("Windows rejected the requested LG mode: " + applyResult);
         }

         return String.Format("LG UltraGear is now {0}x{1} at {2} Hz.", width, height, refreshRate);
      }
   }
}
'@
}

Write-Host ([Dotfiles.LgDisplayMode]::Ensure($Width, $Height, $RefreshRate))

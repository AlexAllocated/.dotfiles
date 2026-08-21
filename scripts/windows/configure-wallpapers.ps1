param(
	[ValidateSet("Ensure", "Apply", "Status", "Remove")]
	[string]$Mode = "Ensure",
	[string]$UltrawidePath = "$env:LOCALAPPDATA\dotfiles\wallpapers\pixel-meadow-hive-3440x1440.png",
	[string]$IpadPath = "$env:LOCALAPPDATA\dotfiles\wallpapers\pixel-meadow-hive-2732x2048.png"
)

$ErrorActionPreference = "Stop"
$TaskName = "Dotfiles Per-Monitor Wallpapers"
$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not ([System.Management.Automation.PSTypeName]"Dotfiles.WallpaperPolicy").Type) {
	Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace Dotfiles {
   internal enum DesktopWallpaperPosition {
      Center = 0,
      Tile = 1,
      Stretch = 2,
      Fit = 3,
      Fill = 4,
      Span = 5
   }

   [StructLayout(LayoutKind.Sequential)]
   internal struct Rect {
      public int Left;
      public int Top;
      public int Right;
      public int Bottom;
   }

   [ComImport]
   [Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B")]
   [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
   internal interface IDesktopWallpaper {
      void SetWallpaper(
         [MarshalAs(UnmanagedType.LPWStr)] string monitorId,
         [MarshalAs(UnmanagedType.LPWStr)] string wallpaper
      );

      [return: MarshalAs(UnmanagedType.LPWStr)]
      string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorId);

      [return: MarshalAs(UnmanagedType.LPWStr)]
      string GetMonitorDevicePathAt(uint monitorIndex);

      uint GetMonitorDevicePathCount();

      void GetMonitorRect(
         [MarshalAs(UnmanagedType.LPWStr)] string monitorId,
         out Rect displayRect
      );

      void SetBackgroundColor(uint color);
      uint GetBackgroundColor();
      void SetPosition(DesktopWallpaperPosition position);
      DesktopWallpaperPosition GetPosition();
   }

   [ComImport]
   [Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD")]
   internal class DesktopWallpaperClass {}

   public sealed class WallpaperAssignment {
      public string MonitorId { get; set; }
      public string Role { get; set; }
      public string Wallpaper { get; set; }
   }

   public static class WallpaperPolicy {
      private static string GetRole(string monitorId) {
         if (monitorId.IndexOf("DISPLAY#GSM774B#", StringComparison.OrdinalIgnoreCase) >= 0) {
            return "LG UltraGear";
         }
         if (monitorId.IndexOf("DISPLAY#MTT1337#", StringComparison.OrdinalIgnoreCase) >= 0) {
            return "iPad VDD";
         }
         return "Other";
      }

      private static IDesktopWallpaper CreateDesktopWallpaper() {
         return (IDesktopWallpaper)new DesktopWallpaperClass();
      }

      private static WallpaperAssignment[] ReadAssignments(IDesktopWallpaper desktop) {
         var assignments = new List<WallpaperAssignment>();
         var count = desktop.GetMonitorDevicePathCount();
         for (uint index = 0; index < count; index++) {
            var monitorId = desktop.GetMonitorDevicePathAt(index);
            assignments.Add(new WallpaperAssignment {
               MonitorId = monitorId,
               Role = GetRole(monitorId),
               Wallpaper = desktop.GetWallpaper(monitorId)
            });
         }
         return assignments.ToArray();
      }

      public static WallpaperAssignment[] Apply(string ultrawidePath, string ipadPath) {
         var desktop = CreateDesktopWallpaper();
         try {
            desktop.SetPosition(DesktopWallpaperPosition.Fill);

            // Make the physical LG crop the Windows default as well as the
            // assignment for every currently attached display. This gives a
            // returning LG the correct image even when a Sunshine session had
            // made the VDD the only active output during reconciliation.
            desktop.SetWallpaper(null, ultrawidePath);
            Thread.Sleep(2000);

            var count = desktop.GetMonitorDevicePathCount();
            for (var attempt = 0; attempt < 3; attempt++) {
               for (uint index = 0; index < count; index++) {
                  var monitorId = desktop.GetMonitorDevicePathAt(index);
                  var role = GetRole(monitorId);
                  if (role == "LG UltraGear") {
                     desktop.SetWallpaper(monitorId, ultrawidePath);
                  } else if (role == "iPad VDD") {
                     desktop.SetWallpaper(monitorId, ipadPath);
                  }
               }

               // SetWallpaper returns before Explorer finishes transcoding a
               // large source. Reassert the monitor-specific image after the
               // global operation settles so it cannot win the race later.
               Thread.Sleep(1000);
               var settled = true;
               for (uint index = 0; index < count; index++) {
                  var monitorId = desktop.GetMonitorDevicePathAt(index);
                  var role = GetRole(monitorId);
                  var expected = role == "LG UltraGear" ? ultrawidePath :
                     role == "iPad VDD" ? ipadPath : ultrawidePath;
                  if (!String.Equals(desktop.GetWallpaper(monitorId), expected, StringComparison.OrdinalIgnoreCase)) {
                     settled = false;
                  }
               }
               if (settled) {
                  break;
               }
            }
            return ReadAssignments(desktop);
         } finally {
            Marshal.FinalReleaseComObject(desktop);
         }
      }

      public static WallpaperAssignment[] Read() {
         var desktop = CreateDesktopWallpaper();
         try {
            return ReadAssignments(desktop);
         } finally {
            Marshal.FinalReleaseComObject(desktop);
         }
      }
   }
}
'@
}

function Assert-WallpaperAssets {
	foreach ($path in @($UltrawidePath, $IpadPath)) {
		if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
			throw "Wallpaper asset not found: $path"
		}
	}
}

function Show-WallpaperAssignments {
	param([Parameter(Mandatory = $true)]$Assignments)

	$Assignments |
		Select-Object Role, MonitorId, Wallpaper |
		Format-List
}

function Apply-Wallpapers {
	Assert-WallpaperAssets
	$assignments = [Dotfiles.WallpaperPolicy]::Apply($UltrawidePath, $IpadPath)
	Show-WallpaperAssignments -Assignments $assignments
	Write-Host "Applied the LG and iPad VDD wallpaper policy."
}

function Install-WallpaperTask {
	$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
	$actionArguments = @(
		"-NoLogo",
		"-NoProfile",
		"-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass",
		"-File", ('"{0}"' -f $PSCommandPath),
		"-Mode", "Apply",
		"-UltrawidePath", ('"{0}"' -f $UltrawidePath),
		"-IpadPath", ('"{0}"' -f $IpadPath)
	) -join " "
	$action = New-ScheduledTaskAction -Execute $PowerShell -Argument $actionArguments
	$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
	$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
	$settings = New-ScheduledTaskSettingsSet `
		-AllowStartIfOnBatteries `
		-DontStopIfGoingOnBatteries `
		-ExecutionTimeLimit ([TimeSpan]::FromMinutes(1)) `
		-MultipleInstances IgnoreNew `
		-StartWhenAvailable

	Register-ScheduledTask `
		-TaskName $TaskName `
		-Description "Assign the matching HiveTech meadow crop to Tracer's LG and iPad virtual displays." `
		-Action $action `
		-Trigger $trigger `
		-Principal $principal `
		-Settings $settings `
		-Force | Out-Null
}

switch ($Mode) {
	"Ensure" {
		Apply-Wallpapers
		Install-WallpaperTask
		Write-Host "Installed the '$TaskName' logon reconciliation task."
	}
	"Apply" { Apply-Wallpapers }
	"Status" {
		Show-WallpaperAssignments -Assignments ([Dotfiles.WallpaperPolicy]::Read())
		Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue |
			Select-Object TaskName, State |
			Format-List
	}
	"Remove" {
		Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
		Write-Host "Removed '$TaskName'."
	}
}

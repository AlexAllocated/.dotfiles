param(
	[ValidateSet("Ensure", "Run", "Pulse", "Status", "Remove")]
	[string]$Mode = "Ensure",
	[int]$IntervalSeconds = 300
)

$ErrorActionPreference = "Stop"
$TaskName = "Dotfiles Slack Presence Pulse"
$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function Initialize-InputApi {
	if (([System.Management.Automation.PSTypeName]"Dotfiles.UserActivity").Type) {
		return
	}

	Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Dotfiles {
   public static class UserActivity {
      private const uint MOUSEEVENTF_MOVE = 0x0001;

      [StructLayout(LayoutKind.Sequential)]
      private struct LASTINPUTINFO {
         public uint cbSize;
         public uint dwTime;
      }

      [DllImport("user32.dll")]
      private static extern void mouse_event(
         uint dwFlags,
         int dx,
         int dy,
         uint dwData,
         UIntPtr dwExtraInfo
      );

      [DllImport("user32.dll")]
      private static extern bool GetLastInputInfo(ref LASTINPUTINFO inputInfo);

      public static void Pulse() {
         mouse_event(MOUSEEVENTF_MOVE, 0, 0, 0, UIntPtr.Zero);
      }

      public static uint IdleMilliseconds() {
         var inputInfo = new LASTINPUTINFO();
         inputInfo.cbSize = (uint)Marshal.SizeOf(inputInfo);
         if (!GetLastInputInfo(ref inputInfo)) {
            throw new InvalidOperationException("GetLastInputInfo failed.");
         }
         return unchecked((uint)Environment.TickCount) - inputInfo.dwTime;
      }
   }
}
'@
}

function Invoke-PresencePulse {
	Initialize-InputApi
	[Dotfiles.UserActivity]::Pulse()
}

function Start-PresenceLoop {
	if ($IntervalSeconds -lt 60) {
		throw "The presence interval must be at least 60 seconds."
	}

	while ($true) {
		Start-Sleep -Seconds $IntervalSeconds
		if (Get-Process -Name slack -ErrorAction SilentlyContinue) {
			Invoke-PresencePulse
		}
	}
}

function Install-PresenceTask {
	$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
	$actionArguments = @(
		"-NoLogo"
		"-NoProfile"
		"-WindowStyle", "Hidden"
		"-ExecutionPolicy", "Bypass"
		"-File", ('"{0}"' -f $PSCommandPath)
		"-Mode", "Run"
		"-IntervalSeconds", $IntervalSeconds
	) -join " "
	$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
	if (
		$existingTask -and
		$existingTask.Actions.Count -eq 1 -and
		$existingTask.Actions[0].Execute -ieq $PowerShell -and
		$existingTask.Actions[0].Arguments -eq $actionArguments -and
		$existingTask.Principal.RunLevel.ToString() -eq "Limited"
	) {
		if ($existingTask.State.ToString() -ne "Running") {
			Start-ScheduledTask -TaskName $TaskName
		}
		Write-Host "'$TaskName' is current with a $IntervalSeconds-second interval."
		return
	}
	$action = New-ScheduledTaskAction -Execute $PowerShell -Argument $actionArguments
	$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
	$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
	$settings = New-ScheduledTaskSettingsSet `
		-AllowStartIfOnBatteries `
		-DontStopIfGoingOnBatteries `
		-ExecutionTimeLimit ([TimeSpan]::Zero) `
		-MultipleInstances IgnoreNew `
		-RestartCount 3 `
		-RestartInterval ([TimeSpan]::FromMinutes(1)) `
		-StartWhenAvailable

	Register-ScheduledTask `
		-TaskName $TaskName `
		-Description "Emit a zero-distance mouse event every five minutes while Slack is running." `
		-Action $action `
		-Trigger $trigger `
		-Principal $principal `
		-Settings $settings `
		-Force | Out-Null
	Start-ScheduledTask -TaskName $TaskName
	Write-Host "Installed and started '$TaskName' with a $IntervalSeconds-second interval."
}

switch ($Mode) {
	"Ensure" { Install-PresenceTask }
	"Run" { Start-PresenceLoop }
	"Pulse" {
		Initialize-InputApi
		$before = [Dotfiles.UserActivity]::IdleMilliseconds()
		Invoke-PresencePulse
		Start-Sleep -Milliseconds 100
		$after = [Dotfiles.UserActivity]::IdleMilliseconds()
		Write-Host "Emitted one zero-distance mouse event; idle time changed from $before ms to $after ms."
	}
	"Status" {
		Initialize-InputApi
		$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
		[pscustomobject]@{
			TaskName = $task.TaskName
			State = $task.State
			IdleSeconds = [Math]::Round([Dotfiles.UserActivity]::IdleMilliseconds() / 1000, 1)
		} | Format-List
	}
	"Remove" {
		Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
		Write-Host "Removed '$TaskName'."
	}
}

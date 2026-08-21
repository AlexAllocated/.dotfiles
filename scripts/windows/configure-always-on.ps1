param(
	[ValidateSet("Ensure", "Install", "Apply")]
	[string]$Mode = "Ensure"
)

$ErrorActionPreference = "Stop"
$TaskName = "Dotfiles Always-On Policy"
$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Invoke-PowerCfg {
	param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

	& powercfg.exe @Arguments | Out-Null
	if ($LASTEXITCODE -ne 0) {
		throw "powercfg.exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
	}
}

function Test-PowerSettingZero {
	param(
		[string]$Scheme = "SCHEME_CURRENT",
		[Parameter(Mandatory = $true)][string]$Subgroup,
		[Parameter(Mandatory = $true)][string]$Setting,
		[switch]$IncludeHidden
	)

	$verb = if ($IncludeHidden) { "/qh" } else { "/query" }
	$output = @(& powercfg.exe $verb $Scheme $Subgroup $Setting)
	if ($LASTEXITCODE -ne 0) {
		return $false
	}
	$indexes = @($output | Select-String -Pattern "Current (AC|DC) Power Setting Index:\s+0x([0-9a-fA-F]+)")
	return $indexes.Count -eq 2 -and @($indexes | Where-Object {
		[Convert]::ToUInt32($_.Matches[0].Groups[2].Value, 16) -ne 0
	}).Count -eq 0
}

function Test-MachinePolicyCurrent {
	$settings = @(
		@{ Subgroup = "SUB_VIDEO"; Setting = "VIDEOIDLE"; IncludeHidden = $false },
		@{ Subgroup = "SUB_DISK"; Setting = "DISKIDLE"; IncludeHidden = $false },
		@{ Subgroup = "SUB_SLEEP"; Setting = "STANDBYIDLE"; IncludeHidden = $false },
		@{ Subgroup = "SUB_SLEEP"; Setting = "HIBERNATEIDLE"; IncludeHidden = $false },
		@{ Subgroup = "SUB_SLEEP"; Setting = "HYBRIDSLEEP"; IncludeHidden = $false },
		@{
			Subgroup = "SUB_SLEEP"
			Setting = "7bc4a2f9-d8fc-4469-b07b-33eb785aaca0"
			IncludeHidden = $true
		}
	)
	foreach ($scheme in @("SCHEME_BALANCED", "SCHEME_MIN", "SCHEME_MAX")) {
		foreach ($setting in $settings) {
			if (-not (Test-PowerSettingZero `
				-Scheme $scheme `
				-Subgroup $setting.Subgroup `
				-Setting $setting.Setting `
				-IncludeHidden:$setting.IncludeHidden)) {
				return $false
			}
		}
	}
	return (
		(Get-ItemPropertyValue `
			-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
			-Name "HibernateEnabled" `
			-ErrorAction SilentlyContinue) -eq 0 -and
		(Get-ItemPropertyValue `
			-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
			-Name "InactivityTimeoutSecs" `
			-ErrorAction SilentlyContinue) -eq 0 -and
		(Get-ItemPropertyValue `
			-Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" `
			-Name "StartupBoostEnabled" `
			-ErrorAction SilentlyContinue) -eq 0 -and
		(Get-ItemPropertyValue `
			-Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" `
			-Name "BackgroundModeEnabled" `
			-ErrorAction SilentlyContinue) -eq 0
	)
}

function Set-MachinePolicy {
	if (-not $isAdministrator) {
		throw "Applying the always-on machine policy requires elevation."
	}

	$settings = @(
		@{ Subgroup = "SUB_VIDEO"; Setting = "VIDEOIDLE" },
		@{ Subgroup = "SUB_DISK"; Setting = "DISKIDLE" },
		@{ Subgroup = "SUB_SLEEP"; Setting = "STANDBYIDLE" },
		@{ Subgroup = "SUB_SLEEP"; Setting = "HIBERNATEIDLE" },
		@{ Subgroup = "SUB_SLEEP"; Setting = "HYBRIDSLEEP" },
		@{ Subgroup = "SUB_SLEEP"; Setting = "7bc4a2f9-d8fc-4469-b07b-33eb785aaca0" }
	)
	# Windows, GPU utilities, and games can switch between the standard power
	# schemes. Keep all three compliant so a scheme switch cannot reintroduce
	# display, disk, sleep, or hibernate timeouts.
	foreach ($scheme in @("SCHEME_BALANCED", "SCHEME_MIN", "SCHEME_MAX")) {
		foreach ($setting in $settings) {
			Invoke-PowerCfg /setacvalueindex $scheme $setting.Subgroup $setting.Setting 0
			Invoke-PowerCfg /setdcvalueindex $scheme $setting.Subgroup $setting.Setting 0
		}
	}

	Invoke-PowerCfg /hibernate off
	Invoke-PowerCfg /setactive SCHEME_CURRENT

	$systemPolicy = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
	Set-ItemProperty -Path $systemPolicy -Name InactivityTimeoutSecs -Type DWord -Value 0

	$edgePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
	New-Item -Path $edgePolicy -Force | Out-Null
	Set-ItemProperty -Path $edgePolicy -Name StartupBoostEnabled -Type DWord -Value 0
	Set-ItemProperty -Path $edgePolicy -Name BackgroundModeEnabled -Type DWord -Value 0
}

function Set-UserPolicy {
	$desktopPolicy = "HKCU:\Control Panel\Desktop"
	Set-ItemProperty -Path $desktopPolicy -Name ScreenSaveActive -Type String -Value "0"
	Set-ItemProperty -Path $desktopPolicy -Name ScreenSaveTimeOut -Type String -Value "0"
	Set-ItemProperty -Path $desktopPolicy -Name ScreenSaverIsSecure -Type String -Value "0"

	$winlogonPolicy = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
	New-Item -Path $winlogonPolicy -Force | Out-Null
	Set-ItemProperty -Path $winlogonPolicy -Name EnableGoodbye -Type DWord -Value 0

	$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
	(Get-ItemProperty -Path $runKey).PSObject.Properties |
		Where-Object Name -Like "MicrosoftEdgeAutoLaunch_*" |
		ForEach-Object {
			Remove-ItemProperty -Path $runKey -Name $_.Name
		}

	$slack = Join-Path $env:LOCALAPPDATA "slack\slack.exe"
	if (Test-Path -LiteralPath $slack) {
		Set-ItemProperty `
			-Path $runKey `
			-Name "com.squirrel.slack.slack" `
			-Type String `
			-Value ('"{0}" --process-start-args --startup' -f $slack)
	}
}

function Test-UserPolicyCurrent {
	$desktopPolicy = "HKCU:\Control Panel\Desktop"
	$winlogonPolicy = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
	$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
	$runProperties = Get-ItemProperty -Path $runKey
	$slack = Join-Path $env:LOCALAPPDATA "slack\slack.exe"
	$slackCurrent = $true
	if (Test-Path -LiteralPath $slack) {
		$slackCurrent = $runProperties."com.squirrel.slack.slack" -eq ('"{0}" --process-start-args --startup' -f $slack)
	}

	return (
		(Get-ItemPropertyValue -Path $desktopPolicy -Name ScreenSaveActive -ErrorAction SilentlyContinue) -eq "0" -and
		(Get-ItemPropertyValue -Path $desktopPolicy -Name ScreenSaveTimeOut -ErrorAction SilentlyContinue) -eq "0" -and
		(Get-ItemPropertyValue -Path $desktopPolicy -Name ScreenSaverIsSecure -ErrorAction SilentlyContinue) -eq "0" -and
		(Get-ItemPropertyValue -Path $winlogonPolicy -Name EnableGoodbye -ErrorAction SilentlyContinue) -eq 0 -and
		@($runProperties.PSObject.Properties | Where-Object Name -Like "MicrosoftEdgeAutoLaunch_*").Count -eq 0 -and
		$slackCurrent
	)
}

function Get-PolicyTaskActionArguments {
	return @(
		"-NoLogo",
		"-NoProfile",
		"-NonInteractive",
		"-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass",
		"-File", ('"{0}"' -f $PSCommandPath),
		"-Mode", "Apply"
	) -join " "
}

function Test-PolicyTaskCurrent {
	$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
	$actionArguments = Get-PolicyTaskActionArguments
	return [bool](
		$task -and
		$task.Actions.Count -eq 1 -and
		$task.Actions[0].Execute -ieq $PowerShell -and
		$task.Actions[0].Arguments -eq $actionArguments -and
		$task.Principal.RunLevel.ToString() -eq "Highest" -and
		$task.Triggers.Count -eq 1 -and
		$task.Triggers[0].CimClass.CimClassName -eq "MSFT_TaskLogonTrigger" -and
		$task.Settings.ExecutionTimeLimit -eq "PT2M" -and
		$task.Settings.MultipleInstances.ToString() -eq "IgnoreNew" -and
		$task.Settings.StartWhenAvailable -eq $true
	)
}

function Install-PolicyTask {
	if (-not $isAdministrator) {
		throw "Installing the always-on policy task requires elevation."
	}

	$identityName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
	$actionArguments = Get-PolicyTaskActionArguments
	$action = New-ScheduledTaskAction -Execute $PowerShell -Argument $actionArguments
	$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identityName
	$principal = New-ScheduledTaskPrincipal `
		-UserId $identityName `
		-LogonType Interactive `
		-RunLevel Highest
	$settings = New-ScheduledTaskSettingsSet `
		-AllowStartIfOnBatteries `
		-DontStopIfGoingOnBatteries `
		-ExecutionTimeLimit ([TimeSpan]::FromMinutes(2)) `
		-MultipleInstances IgnoreNew `
		-StartWhenAvailable

	Register-ScheduledTask `
		-TaskName $TaskName `
		-Description "Keep Tracer awake and prevent background Edge preloading." `
		-Action $action `
		-Trigger $trigger `
		-Principal $principal `
		-Settings $settings `
		-Force | Out-Null
}

function Invoke-ElevatedInstall {
	$arguments = @(
		"-NoLogo",
		"-NoProfile",
		"-ExecutionPolicy", "Bypass",
		"-File", ('"{0}"' -f $PSCommandPath),
		"-Mode", "Install"
	)
	$process = Start-Process `
		-FilePath $PowerShell `
		-Verb RunAs `
		-Wait `
		-PassThru `
		-ArgumentList $arguments
	if ($process.ExitCode -ne 0) {
		throw "Elevated always-on policy installation exited with status $($process.ExitCode)."
	}
}

function Invoke-PolicyTask {
	$startedAt = Get-Date
	Start-ScheduledTask -TaskName $TaskName
	$deadline = $startedAt.AddSeconds(30)
	do {
		Start-Sleep -Milliseconds 250
		$task = Get-ScheduledTask -TaskName $TaskName
		$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
		$hasRun = $taskInfo.LastRunTime -ge $startedAt.AddSeconds(-2)
		if ($hasRun -and $task.State -ne "Running") {
			if ([int64]$taskInfo.LastTaskResult -ne 0) {
				throw "The elevated '$TaskName' task failed with exit code $($taskInfo.LastTaskResult)."
			}
			if (-not (Test-MachinePolicyCurrent)) {
				throw "The elevated '$TaskName' task completed without repairing the machine policy."
			}
			return
		}
	} while ((Get-Date) -lt $deadline)

	throw "Timed out waiting for the elevated '$TaskName' task."
}

function Write-PolicySummary {
	Write-Host "Windows is configured to keep the display, disks, and workstation awake indefinitely."
	Write-Host "Hibernate, hybrid sleep, screen saver locking, Dynamic Lock, and inactivity locking are disabled."
	Write-Host "Slack is registered to start automatically at login."
	Write-Host "Microsoft Edge background mode, Startup Boost, and login preloading are disabled."
}

switch ($Mode) {
	"Apply" {
		if (-not (Test-MachinePolicyCurrent)) {
			Set-MachinePolicy
		}
		if (-not (Test-UserPolicyCurrent)) {
			Set-UserPolicy
		}
		Write-PolicySummary
	}
	"Install" {
		Install-PolicyTask
		Set-MachinePolicy
		Set-UserPolicy
		Write-PolicySummary
	}
	"Ensure" {
		if (-not (Test-UserPolicyCurrent)) {
			Set-UserPolicy
		}
		if ($isAdministrator) {
			if (-not (Test-PolicyTaskCurrent)) {
				Install-PolicyTask
			}
			if (-not (Test-MachinePolicyCurrent)) {
				Set-MachinePolicy
			}
		} else {
			if (-not (Test-PolicyTaskCurrent)) {
				Write-Host "Requesting one-time elevation to install the always-on policy task..."
				Invoke-ElevatedInstall
			} elseif (-not (Test-MachinePolicyCurrent)) {
				Write-Host "Repairing the always-on machine policy through '$TaskName'..."
				Invoke-PolicyTask
			}
		}
		if (-not (Test-MachinePolicyCurrent)) {
			throw "The always-on machine policy remains out of date after reconciliation."
		}
		Write-PolicySummary
	}
}

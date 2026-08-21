param()

$ErrorActionPreference = "Stop"

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
		[Parameter(Mandatory = $true)][string]$Subgroup,
		[Parameter(Mandatory = $true)][string]$Setting,
		[switch]$IncludeHidden
	)

	$verb = if ($IncludeHidden) { "/qh" } else { "/query" }
	$output = @(& powercfg.exe $verb SCHEME_CURRENT $Subgroup $Setting)
	if ($LASTEXITCODE -ne 0) {
		return $false
	}
	$indexes = @($output | Select-String -Pattern "Current (AC|DC) Power Setting Index:\s+0x([0-9a-fA-F]+)")
	return $indexes.Count -eq 2 -and @($indexes | Where-Object {
		[Convert]::ToUInt32($_.Matches[0].Groups[2].Value, 16) -ne 0
	}).Count -eq 0
}

$machinePolicyCurrent =
	(Test-PowerSettingZero -Subgroup "SUB_VIDEO" -Setting "VIDEOIDLE") -and
	(Test-PowerSettingZero -Subgroup "SUB_DISK" -Setting "DISKIDLE") -and
	(Test-PowerSettingZero -Subgroup "SUB_SLEEP" -Setting "STANDBYIDLE") -and
	(Test-PowerSettingZero -Subgroup "SUB_SLEEP" -Setting "HIBERNATEIDLE") -and
	(Test-PowerSettingZero -Subgroup "SUB_SLEEP" -Setting "HYBRIDSLEEP") -and
	(Test-PowerSettingZero `
		-Subgroup "SUB_SLEEP" `
		-Setting "7bc4a2f9-d8fc-4469-b07b-33eb785aaca0" `
		-IncludeHidden) -and
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

if ($isAdministrator) {
	foreach ($powerSource in @("ac", "dc")) {
		Invoke-PowerCfg /change "monitor-timeout-$powerSource" 0
		Invoke-PowerCfg /change "disk-timeout-$powerSource" 0
		Invoke-PowerCfg /change "standby-timeout-$powerSource" 0
		Invoke-PowerCfg /change "hibernate-timeout-$powerSource" 0
	}

	Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 0
	Invoke-PowerCfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 0
	Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0
	Invoke-PowerCfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0
	Invoke-PowerCfg /hibernate off
	Invoke-PowerCfg /setactive SCHEME_CURRENT
} elseif (-not $machinePolicyCurrent) {
	throw "The always-on machine policy needs repair; rerun the Windows integration elevated."
}

$desktopPolicy = "HKCU:\Control Panel\Desktop"
Set-ItemProperty -Path $desktopPolicy -Name ScreenSaveActive -Type String -Value "0"
Set-ItemProperty -Path $desktopPolicy -Name ScreenSaveTimeOut -Type String -Value "0"
Set-ItemProperty -Path $desktopPolicy -Name ScreenSaverIsSecure -Type String -Value "0"

$winlogonPolicy = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
New-Item -Path $winlogonPolicy -Force | Out-Null
Set-ItemProperty -Path $winlogonPolicy -Name EnableGoodbye -Type DWord -Value 0

if ($isAdministrator) {
	$systemPolicy = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
	Set-ItemProperty -Path $systemPolicy -Name InactivityTimeoutSecs -Type DWord -Value 0

	$edgePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
	New-Item -Path $edgePolicy -Force | Out-Null
	Set-ItemProperty -Path $edgePolicy -Name StartupBoostEnabled -Type DWord -Value 0
	Set-ItemProperty -Path $edgePolicy -Name BackgroundModeEnabled -Type DWord -Value 0
}

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

Write-Host "Windows is configured to keep the display, disks, and workstation awake indefinitely."
Write-Host "Hibernate, hybrid sleep, screen saver locking, Dynamic Lock, and inactivity locking are disabled."
Write-Host "Slack is registered to start automatically at login."
Write-Host "Microsoft Edge background mode, Startup Boost, and login preloading are disabled."

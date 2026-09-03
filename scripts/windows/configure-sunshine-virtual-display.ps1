param(
	[ValidateSet("Ensure", "Apply")]
	[string]$Mode = "Ensure",
	[string]$ConfigurationPath = "$env:ProgramFiles\Sunshine\config\sunshine.conf",
	[string]$OutputStatePath = "$env:LOCALAPPDATA\dotfiles\virtual-display\sunshine-output-name.txt",
	[string]$ServiceName = "SunshineService",
	[string]$StreamingMixName = "Speakers (Steam Streaming Speakers)",
	[string]$FrameLimitScriptPath = "$env:LOCALAPPDATA\dotfiles\set-nvidia-frame-limit.ps1"
)

$ErrorActionPreference = "Stop"
$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$virtualDisplays = @(Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue |
	Where-Object FriendlyName -EQ "Virtual Display Driver")
if ($virtualDisplays.Count -ne 1 -or $virtualDisplays[0].Status -ne "OK") {
	throw "Expected exactly one healthy Virtual Display Driver, found $($virtualDisplays.Count)."
}

$outputName = if (Test-Path -LiteralPath $OutputStatePath) {
	(Get-Content -LiteralPath $OutputStatePath -Raw).Trim()
} else {
	$null
}
if (-not $outputName -and (Test-Path -LiteralPath $ConfigurationPath)) {
	foreach ($line in Get-Content -LiteralPath $ConfigurationPath) {
		if ($line -match '^\s*output_name\s*=\s*(\{[0-9A-Fa-f-]+\})\s*$') {
			$outputName = $Matches[1]
			break
		}
	}
}
if ($outputName -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
	throw "The machine-local Sunshine VDD output identity is missing or invalid: $OutputStatePath"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $OutputStatePath) -Force | Out-Null
[IO.File]::WriteAllText($OutputStatePath, "$outputName`r`n", [Text.UTF8Encoding]::new($false))

$audioInfoPath = Join-Path $env:ProgramFiles "Sunshine\tools\audio-info.exe"
if (-not (Test-Path -LiteralPath $audioInfoPath -PathType Leaf)) {
	throw "Sunshine audio endpoint inventory is missing: $audioInfoPath"
}
$audioInventory = (& $audioInfoPath 2>&1 | Out-String)
if ($audioInventory -notmatch "(?m)^Device name\s*:\s*$([regex]::Escape($StreamingMixName))\s*$") {
	throw "AudioArray's streaming-mix endpoint is unavailable to Sunshine: $StreamingMixName"
}
if (-not (Test-Path -LiteralPath $FrameLimitScriptPath -PathType Leaf)) {
	throw "Sunshine's NVIDIA frame-limit hook is unavailable: $FrameLimitScriptPath"
}

$frameLimitDo = ('"{0}" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Mode Vdd' -f $PowerShell, $FrameLimitScriptPath)
$frameLimitUndo = ('"{0}" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Mode Local' -f $PowerShell, $FrameLimitScriptPath)
$globalPrepCommand = ConvertTo-Json -InputObject @(
	[ordered]@{
		do = $frameLimitDo
		undo = $frameLimitUndo
		elevated = $true
	}
) -Compress
$settings = [ordered]@{
	output_name = $outputName
	dd_configuration_option = "ensure_only_display"
	dd_resolution_option = "auto"
	dd_refresh_rate_option = "auto"
	dd_hdr_option = "auto"
	dd_config_revert_on_disconnect = "enabled"
	# Sunshine makes this sink the Windows default only while a client is
	# connected. AudioArray observes that real endpoint transition directly.
	virtual_sink = $StreamingMixName
	install_steam_audio_drivers = "disabled"
	global_prep_cmd = $globalPrepCommand
}

$obsoleteSettings = @(
	"audio_sink"
	"dd_manual_resolution"
	"dd_manual_refresh_rate"
)

$lines = if (Test-Path -LiteralPath $ConfigurationPath) {
	@(Get-Content -LiteralPath $ConfigurationPath)
} else {
	@()
}
$seen = @{}
$updatedLines = [Collections.Generic.List[string]]::new()
foreach ($line in $lines) {
	$obsoleteSetting = $obsoleteSettings | Where-Object {
		$line -match "^\s*$([regex]::Escape($_))\s*="
	} | Select-Object -First 1
	if ($obsoleteSetting) {
		continue
	}
	$matchedKey = $null
	foreach ($key in $settings.Keys) {
		if ($line -match "^\s*$([regex]::Escape($key))\s*=") {
			$matchedKey = $key
			break
		}
	}
	if ($matchedKey) {
		if (-not $seen.ContainsKey($matchedKey)) {
			$seen[$matchedKey] = $true
			$updatedLines.Add("$matchedKey = $($settings[$matchedKey])")
		}
	} else {
		$updatedLines.Add($line)
	}
}
foreach ($key in $settings.Keys) {
	if (-not $seen.ContainsKey($key)) {
		$updatedLines.Add("$key = $($settings[$key])")
	}
}

$currentConfiguration = ($lines -join "`n").TrimEnd()
$desiredConfiguration = (@($updatedLines) -join "`n").TrimEnd()
$configurationIsCurrent = $currentConfiguration -ceq $desiredConfiguration

function Invoke-ElevatedApply {
	$arguments = @(
		"-NoLogo",
		"-NoProfile",
		"-ExecutionPolicy", "Bypass",
		"-File", ('"{0}"' -f $PSCommandPath),
		"-Mode", "Apply"
	)
	$process = Start-Process `
		-FilePath $PowerShell `
		-Verb RunAs `
		-Wait `
		-PassThru `
		-ArgumentList $arguments
	if ($process.ExitCode -ne 0) {
		throw "Elevated Sunshine configuration exited with status $($process.ExitCode)."
	}
}

if ($Mode -eq "Ensure" -and $configurationIsCurrent) {
	Write-Host "Sunshine's VDD, AudioArray, and adaptive NVIDIA frame-limit settings are current."
	exit 0
}
if (-not $isAdministrator) {
	if ($Mode -eq "Apply") {
		throw "Applying Sunshine's display configuration requires elevation."
	}
	Write-Host "Requesting elevation to update Sunshine's session-aware frame limiter..."
	Invoke-ElevatedApply
	exit 0
}

$backupDirectory = Join-Path $env:LOCALAPPDATA "dotfiles\backups"
New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
if (Test-Path -LiteralPath $ConfigurationPath) {
	$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
	Copy-Item `
		-LiteralPath $ConfigurationPath `
		-Destination (Join-Path $backupDirectory "sunshine.conf-$stamp")
}

[IO.File]::WriteAllLines(
	$ConfigurationPath,
	$updatedLines,
	[Text.UTF8Encoding]::new($false)
)

& $FrameLimitScriptPath -Mode Local
Restart-Service -Name $ServiceName -Force
(Get-Service -Name $ServiceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(15))

Write-Host "Sunshine now targets $outputName (VDD by MTT)."
Write-Host "Resolution, refresh rate, and HDR now follow the Moonlight client request."
Write-Host "AudioArray now follows Sunshine's real $StreamingMixName default-device transitions."
Write-Host "The NVIDIA driver now limits local play to 158 FPS and reserves three frames of headroom on Moonlight."

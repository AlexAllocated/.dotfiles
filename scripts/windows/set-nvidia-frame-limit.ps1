param(
	[Parameter(Mandatory = $true)]
	[ValidateSet("Vdd", "Local", "Production", "RestoreProduction")]
	[string]$Mode,
	[int]$LocalFrameLimit = 158,
	[int]$ProductionFrameLimit = 60,
	[int]$MinimumFrameLimit = 30,
	[string]$StateDirectory = "$env:ProgramData\dotfiles\nvidia-frame-limit",
	[string]$ProfileInspectorPath = ""
)

$ErrorActionPreference = "Stop"
$FrameRateLimiterSettingId = 277041154 # NVAPI FRL_FPS_ID / 0x10835002

function Test-IsAdministrator {
	$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$principal = [Security.Principal.WindowsPrincipal]::new($identity)
	return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-ProfileInspector {
	if ($ProfileInspectorPath) {
		if (-not (Test-Path -LiteralPath $ProfileInspectorPath -PathType Leaf)) {
			throw "NVIDIA Profile Inspector was not found at $ProfileInspectorPath."
		}
		return (Resolve-Path -LiteralPath $ProfileInspectorPath).Path
	}

	$command = Get-Command nvpi.exe, nvidiaProfileInspector.exe, nvpi -ErrorAction SilentlyContinue |
		Select-Object -First 1
	if ($command) {
		return $command.Source
	}

	# Sunshine runs its elevated preparation commands as a service account, so
	# its LOCALAPPDATA is not Alex's. Derive the interactive user's LocalAppData
	# from this script's installed location instead.
	$userLocalAppData = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
	$packageRoot = Join-Path $userLocalAppData "Microsoft\WinGet\Packages"
	$installed = Get-ChildItem `
		-LiteralPath $packageRoot `
		-Filter "nvidiaProfileInspector.exe" `
		-File `
		-Recurse `
		-ErrorAction SilentlyContinue |
		Where-Object FullName -Like "*Orbmu2k.nvidiaProfileInspector*" |
		Sort-Object LastWriteTime -Descending |
		Select-Object -First 1
	if (-not $installed) {
		throw "NVIDIA Profile Inspector is unavailable. Reconcile the Windows WinGet manifest first."
	}
	return $installed.FullName
}

function Get-TargetFrameLimit {
	if ($Mode -eq "Local") {
		return $LocalFrameLimit
	}

	$refreshRate = 0
	if ($env:SUNSHINE_CLIENT_FPS -match '^\d+$') {
		$refreshRate = [int]$env:SUNSHINE_CLIENT_FPS
	}
	if ($refreshRate -le 0) {
		$refreshRate = 120
	}
	return [Math]::Max($MinimumFrameLimit, $refreshRate - 3)
}

function Read-LimiterState {
	param([Parameter(Mandatory = $true)][string]$Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return $null
	}
	try {
		return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
	} catch {
		Write-Warning "Ignoring invalid NVIDIA frame-limiter state at $Path."
		return $null
	}
}

function Write-LimiterState {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$StateMode,
		[Parameter(Mandatory = $true)][int]$FrameLimit
	)

	$state = [ordered]@{
		mode = $StateMode
		frameLimit = $FrameLimit
		appliedAt = [DateTimeOffset]::Now.ToString("O")
	}
	[IO.File]::WriteAllText(
		$Path,
		($state | ConvertTo-Json -Depth 3),
		[Text.UTF8Encoding]::new($false)
	)
}

if (-not (Test-IsAdministrator)) {
	throw "Changing the NVIDIA driver frame limiter requires elevation. Sunshine runs this hook elevated automatically."
}

New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
$statePath = Join-Path $StateDirectory "current.json"
$restorePath = Join-Path $StateDirectory "obs-production-restore.json"
$currentState = Read-LimiterState -Path $statePath
$effectiveMode = $Mode

if ($Mode -eq "Production") {
	if ($null -eq $currentState -or $currentState.mode -ne "Production") {
		$priorMode = if ($null -ne $currentState -and $currentState.mode) {
			[string]$currentState.mode
		} else {
			"Local"
		}
		$priorLimit = if ($null -ne $currentState -and $currentState.frameLimit) {
			[int]$currentState.frameLimit
		} else {
			$LocalFrameLimit
		}
		Write-LimiterState -Path $restorePath -StateMode $priorMode -FrameLimit $priorLimit
	}
	$baselineLimit = if ($null -ne $currentState -and $currentState.frameLimit) {
		[int]$currentState.frameLimit
	} else {
		$LocalFrameLimit
	}
	$targetFrameLimit = [Math]::Min($baselineLimit, $ProductionFrameLimit)
} elseif ($Mode -eq "RestoreProduction") {
	if ($null -eq $currentState -or $currentState.mode -ne "Production") {
		Remove-Item -LiteralPath $restorePath -Force -ErrorAction SilentlyContinue
		Write-Host "The active NVIDIA frame policy already supersedes OBS production mode."
		exit 0
	}
	$restoreState = Read-LimiterState -Path $restorePath
	if ($null -ne $restoreState -and $restoreState.frameLimit) {
		$effectiveMode = if ($restoreState.mode) { [string]$restoreState.mode } else { "Local" }
		$targetFrameLimit = [int]$restoreState.frameLimit
	} else {
		$effectiveMode = "Local"
		$targetFrameLimit = $LocalFrameLimit
	}
} else {
	$targetFrameLimit = Get-TargetFrameLimit
	# A display-session transition is newer than any OBS snapshot. Never let a
	# later OBS stop event overwrite the VDD/local policy selected by Sunshine.
	Remove-Item -LiteralPath $restorePath -Force -ErrorAction SilentlyContinue
}

$alreadyApplied =
	($null -ne $currentState) -and
	([int]$currentState.frameLimit -eq $targetFrameLimit) -and
	([string]$currentState.mode -eq $effectiveMode)
if ($alreadyApplied) {
	Write-Host "NVIDIA's $effectiveMode frame limit is already $targetFrameLimit FPS."
	exit 0
}

$frameLimitChanged =
	($null -eq $currentState) -or
	([int]$currentState.frameLimit -ne $targetFrameLimit)
$profilePath = Join-Path $StateDirectory "frame-limit-$targetFrameLimit.nip"
$profileXml = @"
<?xml version="1.0" encoding="utf-16"?>
<ArrayOfProfile>
  <Profile>
    <ProfileName>Base Profile</ProfileName>
    <Executeables />
    <Settings>
      <ProfileSetting>
        <SettingNameInfo>Frame Rate Limiter V3</SettingNameInfo>
        <SettingID>$FrameRateLimiterSettingId</SettingID>
        <SettingValue>$targetFrameLimit</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
    </Settings>
    <ExecutableFindFiles />
  </Profile>
</ArrayOfProfile>
"@
[IO.File]::WriteAllText($profilePath, $profileXml, [Text.Encoding]::Unicode)

if ($frameLimitChanged) {
	$profileInspector = Resolve-ProfileInspector
	$process = Start-Process `
		-FilePath $profileInspector `
		-ArgumentList @(
			"-silentImport",
			"-mergeImport",
			"-disableScan",
			('"{0}"' -f $profilePath)
		) `
		-WindowStyle Hidden `
		-PassThru `
		-Wait
	if ($process.ExitCode -ne 0) {
		throw "NVIDIA Profile Inspector exited with status $($process.ExitCode)."
	}
}

Write-LimiterState -Path $statePath -StateMode $effectiveMode -FrameLimit $targetFrameLimit
if ($Mode -eq "RestoreProduction") {
	Remove-Item -LiteralPath $restorePath -Force -ErrorAction SilentlyContinue
}
Write-Host "NVIDIA's global frame limiter is now $targetFrameLimit FPS for $effectiveMode mode."

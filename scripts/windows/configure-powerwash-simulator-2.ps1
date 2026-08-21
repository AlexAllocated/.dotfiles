param(
	[ValidateSet("Ensure", "Launch", "Restore")]
	[string]$Mode = "Ensure",

	[Parameter(Position = 0)]
	[string]$GameExecutable = "",

	[Parameter(ValueFromRemainingArguments = $true)]
	[string[]]$GameArguments = @(),

	[int]$Width = 2560,

	[int]$Height = 1440
)

$ErrorActionPreference = "Stop"

$preferencesPath = Join-Path $env:USERPROFILE `
	"AppData\LocalLow\FuturLab\PowerWash Simulator 2\PC_Steam\SaveData\preferences\futurplayerprefs"
$legacyBackupPath = "$preferencesPath.dotfiles-original"
$backupDirectory = Join-Path $env:LOCALAPPDATA "dotfiles\backups\powerwash-simulator-2"
$backupPath = Join-Path $backupDirectory "futurplayerprefs.original"
$playerPrefsPath = "HKCU:\Software\FuturLab\PowerWash Simulator 2"
$steamRoot = Join-Path ${env:ProgramFiles(x86)} "Steam"
$launcherPath = Join-Path $env:LOCALAPPDATA "dotfiles\configure-powerwash-simulator-2.ps1"
$hiddenLauncherSourcePath = Join-Path (Split-Path -Parent $PSCommandPath) "PowerWashLauncher.cs"
$hiddenLauncherPath = Join-Path $env:LOCALAPPDATA "dotfiles\PowerWashLauncher.exe"
$steamLaunchOptions = "`"$hiddenLauncherPath`" %command%"

New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
if (Test-Path -LiteralPath $legacyBackupPath) {
	if (-not (Test-Path -LiteralPath $backupPath)) {
		Copy-Item -LiteralPath $legacyBackupPath -Destination $backupPath
	}
	Remove-Item -LiteralPath $legacyBackupPath -Force
}

function Find-ByteSequence {
	param(
		[Parameter(Mandatory)][byte[]]$Bytes,
		[Parameter(Mandatory)][byte[]]$Needle
	)

	for ($offset = 0; $offset -le $Bytes.Length - $Needle.Length; $offset++) {
		$matches = $true
		for ($index = 0; $index -lt $Needle.Length; $index++) {
			if ($Bytes[$offset + $index] -ne $Needle[$index]) {
				$matches = $false
				break
			}
		}
		if ($matches) {
			return $offset
		}
	}

	return -1
}

function Read-7BitEncodedInteger {
	param(
		[Parameter(Mandatory)][byte[]]$Bytes,
		[Parameter(Mandatory)][ref]$Offset
	)

	$value = 0
	$shift = 0
	do {
		if ($Offset.Value -ge $Bytes.Length -or $shift -ge 35) {
			throw "The PowerWash Simulator 2 preference payload has an invalid length."
		}
		$current = $Bytes[$Offset.Value]
		$Offset.Value++
		$value = $value -bor (($current -band 0x7f) -shl $shift)
		$shift += 7
	} while (($current -band 0x80) -ne 0)

	return $value
}

function ConvertTo-7BitEncodedInteger {
	param([Parameter(Mandatory)][int]$Value)

	$output = [Collections.Generic.List[byte]]::new()
	$current = [uint32]$Value
	do {
		$next = [byte]($current -band 0x7f)
		$current = $current -shr 7
		if ($current -ne 0) {
			$next = $next -bor 0x80
		}
		$output.Add($next)
	} while ($current -ne 0)

	return $output.ToArray()
}

function Get-PhysicalPrimaryScreen {
	# PowerShell launched through WSL is DPI-unaware by default, which makes the
	# 2732x2048 VDD look like an 1821x1365 display at 150% scaling. Use physical
	# pixels so Unity receives the same dimensions as Sunshine and Windows.
	if (-not ("PowerWashDpiAwareness" -as [type])) {
		Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PowerWashDpiAwareness {
	[DllImport("user32.dll")]
	public static extern bool SetProcessDPIAware();
}
"@
	}
	[void][PowerWashDpiAwareness]::SetProcessDPIAware()
	Add-Type -AssemblyName System.Windows.Forms
	return [Windows.Forms.Screen]::PrimaryScreen.Bounds
}

function Build-HiddenLauncher {
	param(
		[Parameter(Mandatory)][string]$SourcePath,
		[Parameter(Mandatory)][string]$DestinationPath
	)

	if (-not (Test-Path -LiteralPath $SourcePath)) {
		throw "The PowerWash hidden-launcher source is missing: $SourcePath"
	}

	$temporaryLauncher = "$DestinationPath.build.exe"
	Remove-Item -LiteralPath $temporaryLauncher -Force -ErrorAction SilentlyContinue
	$compilerParameters = [CodeDom.Compiler.CompilerParameters]::new()
	$compilerParameters.GenerateExecutable = $true
	$compilerParameters.OutputAssembly = $temporaryLauncher
	$compilerParameters.CompilerOptions = "/target:winexe"
	[void]$compilerParameters.ReferencedAssemblies.Add("System.dll")
	Add-Type -Path $SourcePath -CompilerParameters $compilerParameters
	Move-Item -LiteralPath $temporaryLauncher -Destination $DestinationPath -Force
}

function Set-SteamLaunchOptions {
	param(
		[Parameter(Mandatory)][string]$SteamDirectory,
		[Parameter(Mandatory)][string]$AppId,
		[AllowEmptyString()][string]$LaunchOptions
	)

	$localConfigs = @(Get-ChildItem `
		-LiteralPath (Join-Path $SteamDirectory "userdata") `
		-Filter "localconfig.vdf" `
		-File `
		-Recurse `
		-ErrorAction SilentlyContinue | Where-Object {
			$_.DirectoryName -like "*\config"
		})
	$changed = 0
	foreach ($localConfig in $localConfigs) {
		$text = [IO.File]::ReadAllText($localConfig.FullName)
		$lines = [Collections.Generic.List[string]]::new()
		$lines.AddRange([string[]]($text -split "\r?\n"))
		$appLine = -1
		$openingBrace = -1
		$closingBrace = -1

		for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
			if ($lines[$lineIndex].Trim() -ne "`"$AppId`"") {
				continue
			}
			$nextLine = $lineIndex + 1
			while ($nextLine -lt $lines.Count -and -not $lines[$nextLine].Trim()) {
				$nextLine++
			}
			if ($nextLine -ge $lines.Count -or $lines[$nextLine].Trim() -ne "{") {
				continue
			}

			$depth = 0
			for ($candidateEnd = $nextLine; $candidateEnd -lt $lines.Count; $candidateEnd++) {
				$trimmed = $lines[$candidateEnd].Trim()
				if ($trimmed -eq "{") {
					$depth++
				} elseif ($trimmed -eq "}") {
					$depth--
					if ($depth -eq 0) {
						break
					}
				}
			}
			if ($depth -ne 0) {
				throw "Could not find the end of Steam app $AppId in $($localConfig.FullName)."
			}

			$block = $lines[($nextLine + 1)..($candidateEnd - 1)] -join "`n"
			if ($block -notmatch '"(LastPlayed|Playtime)"') {
				continue
			}
			$appLine = $lineIndex
			$openingBrace = $nextLine
			$closingBrace = $candidateEnd
			break
		}

		if ($appLine -lt 0) {
			continue
		}

		$launchLine = -1
		for ($lineIndex = $openingBrace + 1; $lineIndex -lt $closingBrace; $lineIndex++) {
			if ($lines[$lineIndex] -match '^\s*"LaunchOptions"\s+') {
				$launchLine = $lineIndex
				break
			}
		}

		if (-not $LaunchOptions) {
			if ($launchLine -ge 0) {
				$lines.RemoveAt($launchLine)
			} else {
				continue
			}
		} else {
			$indent = ([regex]::Match($lines[$appLine], '^\s*').Value) + "`t"
			$escapedLaunchOptions = $LaunchOptions.Replace('\', '\\').Replace('"', '\"')
			$desiredLine = "$indent`"LaunchOptions`"`t`t" + "`"$escapedLaunchOptions`""
			if ($launchLine -ge 0) {
				if ($lines[$launchLine] -eq $desiredLine) {
					continue
				}
				$lines[$launchLine] = $desiredLine
			} else {
				$lines.Insert($openingBrace + 1, $desiredLine)
			}
		}

		$updatedText = $lines -join "`r`n"
		[IO.File]::WriteAllText($localConfig.FullName, $updatedText, [Text.UTF8Encoding]::new($false))
		$changed++
	}

	return $changed
}

function Set-PowerWashPreferences {
	param(
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][int]$TargetWidth,
		[Parameter(Mandatory)][int]$TargetHeight,
		[Parameter(Mandatory)][ValidateSet("Borderless", "Windowed")][string]$WindowMode
	)

	$bytes = [IO.File]::ReadAllBytes($Path)
	$marker = [Text.Encoding]::UTF8.GetBytes("PWS2_SETTINGS")
	$markerOffset = Find-ByteSequence -Bytes $bytes -Needle $marker
	if ($markerOffset -lt 0) {
		throw "Could not find the PWS2_SETTINGS record in $Path."
	}

	# The file is a BinaryWriter dictionary. The byte after the key is the
	# string type marker, followed by a 7-bit encoded UTF-8 payload length.
	$lengthOffset = $markerOffset + $marker.Length + 1
	$payloadOffset = $lengthOffset
	$payloadLength = Read-7BitEncodedInteger -Bytes $bytes -Offset ([ref]$payloadOffset)
	if ($payloadOffset + $payloadLength -gt $bytes.Length) {
		throw "The PWS2_SETTINGS payload extends beyond the preference file."
	}

	$json = [Text.Encoding]::UTF8.GetString($bytes, $payloadOffset, $payloadLength)
	$settings = $json | ConvertFrom-Json
	$settings.Resolution = "$TargetWidth x $TargetHeight"
	$settings.WindowMode = $WindowMode
	$updatedJson = $settings | ConvertTo-Json -Compress -Depth 100
	$updatedPayload = [Text.Encoding]::UTF8.GetBytes($updatedJson)
	$updatedLength = ConvertTo-7BitEncodedInteger -Value $updatedPayload.Length

	$output = [Collections.Generic.List[byte]]::new()
	$output.AddRange([byte[]]$bytes[0..($lengthOffset - 1)])
	$output.AddRange([byte[]]$updatedLength)
	$output.AddRange([byte[]]$updatedPayload)
	$suffixOffset = $payloadOffset + $payloadLength
	if ($suffixOffset -lt $bytes.Length) {
		$output.AddRange([byte[]]$bytes[$suffixOffset..($bytes.Length - 1)])
	}

	$temporaryPath = "$Path.dotfiles-new"
	try {
		[IO.File]::WriteAllBytes($temporaryPath, $output.ToArray())
		Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
	} finally {
		Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
	}
}

function Set-UnityDisplayPreferences {
	param(
		[Parameter(Mandatory)][int]$TargetWidth,
		[Parameter(Mandatory)][int]$TargetHeight,
		[Parameter(Mandatory)][int]$FullscreenMode,
		[Parameter(Mandatory)][int]$WindowX,
		[Parameter(Mandatory)][int]$WindowY
	)

	New-Item -Path $playerPrefsPath -Force | Out-Null
	$playerPrefs = [ordered]@{
		"Screenmanager Resolution Width_h182942802" = $TargetWidth
		"Screenmanager Resolution Height_h2627697771" = $TargetHeight
		"Screenmanager Resolution Use Native_h1405027254" = 0
		"Screenmanager Fullscreen mode_h3630240806" = $FullscreenMode
		"Screenmanager Window Position X_h4088080503" = $WindowX
		"Screenmanager Window Position Y_h4088080502" = $WindowY
	}
	foreach ($entry in $playerPrefs.GetEnumerator()) {
		Set-ItemProperty -Path $playerPrefsPath -Name $entry.Key -Type DWord -Value $entry.Value
	}
}

if ($Mode -eq "Launch") {
	if (-not $GameExecutable -or -not (Test-Path -LiteralPath $GameExecutable)) {
		throw "Steam did not provide the PowerWash Simulator 2 executable to its adaptive launcher."
	}

	$screen = Get-PhysicalPrimaryScreen
	$aspectRatio = $screen.Width / [double]$screen.Height
	if ($aspectRatio -lt 1.7) {
		$targetWidth = [Math]::Min($Width, $screen.Width)
		$targetHeight = [Math]::Min($Height, $screen.Height)
		# Preserve 16:9 if a future tall display is smaller than the preferred
		# 2560x1440 workaround size.
		if ($targetWidth / [double]$targetHeight -lt (16.0 / 9.0)) {
			$targetHeight = [Math]::Floor($targetWidth * 9.0 / 16.0)
		} else {
			$targetWidth = [Math]::Floor($targetHeight * 16.0 / 9.0)
		}
		$windowMode = "Borderless"
		$fullscreenMode = 1
		$screenFullscreen = 1
		$windowX = $screen.X + [Math]::Floor(($screen.Width - $targetWidth) / 2)
		$windowY = $screen.Y + [Math]::Floor(($screen.Height - $targetHeight) / 2)
	} else {
		$targetWidth = $screen.Width
		$targetHeight = $screen.Height
		$windowMode = "Borderless"
		$fullscreenMode = 1
		$screenFullscreen = 1
		$windowX = $screen.X
		$windowY = $screen.Y
	}

	if (Test-Path -LiteralPath $preferencesPath) {
		Set-PowerWashPreferences `
			-Path $preferencesPath `
			-TargetWidth $targetWidth `
			-TargetHeight $targetHeight `
			-WindowMode $windowMode
	}
	Set-UnityDisplayPreferences `
		-TargetWidth $targetWidth `
		-TargetHeight $targetHeight `
		-FullscreenMode $fullscreenMode `
		-WindowX $windowX `
		-WindowY $windowY

	$displayArguments = @(
		"-screen-width", "$targetWidth",
		"-screen-height", "$targetHeight",
		"-screen-fullscreen", "$screenFullscreen"
	)
	& $GameExecutable @GameArguments @displayArguments
	exit $LASTEXITCODE
}

if ($Mode -eq "Restore") {
	if (-not (Test-Path -LiteralPath $backupPath)) {
		throw "No original PowerWash Simulator 2 preference backup exists at $backupPath."
	}
	if (Get-Process -Name "PowerWash Simulator 2" -ErrorAction SilentlyContinue) {
		throw "Close PowerWash Simulator 2 before restoring its original preferences."
	}
	Copy-Item -LiteralPath $backupPath -Destination $preferencesPath -Force
	if (-not (Get-Process -Name "steam" -ErrorAction SilentlyContinue)) {
		[void](Set-SteamLaunchOptions -SteamDirectory $steamRoot -AppId "2968420" -LaunchOptions "")
	} else {
		Write-Warning "Steam is running, so its PowerWash Simulator 2 launch options were not removed."
	}
	Write-Host "Restored the original PowerWash Simulator 2 display preferences."
	exit 0
}

if (-not (Test-Path -LiteralPath $preferencesPath)) {
	Write-Host "PowerWash Simulator 2 has not created its preference file yet; skipping its iPad layout workaround."
	exit 0
}
if (Get-Process -Name "PowerWash Simulator 2" -ErrorAction SilentlyContinue) {
	throw "Close PowerWash Simulator 2 before applying its iPad layout workaround."
}
if (-not (Test-Path -LiteralPath $backupPath)) {
	Copy-Item -LiteralPath $preferencesPath -Destination $backupPath
}

$launcherDirectory = Split-Path -Parent $launcherPath
New-Item -ItemType Directory -Path $launcherDirectory -Force | Out-Null
if (([IO.Path]::GetFullPath($PSCommandPath)) -ne ([IO.Path]::GetFullPath($launcherPath))) {
	Copy-Item -LiteralPath $PSCommandPath -Destination $launcherPath -Force
}
Build-HiddenLauncher `
	-SourcePath $hiddenLauncherSourcePath `
	-DestinationPath $hiddenLauncherPath

$steamRunning = [bool](Get-Process -Name "steam" -ErrorAction SilentlyContinue)
if ($steamRunning) {
	Write-Warning "Steam is running; retaining its existing launch-options file during this pass."
} else {
	$updatedSteamConfigs = Set-SteamLaunchOptions `
		-SteamDirectory $steamRoot `
		-AppId "2968420" `
		-LaunchOptions $steamLaunchOptions
	if ($updatedSteamConfigs -eq 0) {
		Write-Warning "PowerWash Simulator 2 was not found in a Steam user configuration."
	}
}

$screen = Get-PhysicalPrimaryScreen
if ($screen.Width / [double]$screen.Height -lt 1.7) {
	Write-Host "PowerWash Simulator 2 will use a centered ${Width}x${Height} borderless window on the current tall display."
} else {
	Write-Host "PowerWash Simulator 2 will use the current display's native $($screen.Width)x$($screen.Height) borderless mode."
}

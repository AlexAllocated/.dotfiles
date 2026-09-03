param(
	[ValidateSet("Ensure", "LaunchValheim", "LaunchValheimFlat", "LaunchPortal2", "LaunchPortal2Flat", "LaunchMcc")]
	[string]$Mode = "Ensure"
)

$ErrorActionPreference = "Stop"

$steamRoot = Join-Path ${env:ProgramFiles(x86)} "Steam"
$stateRoot = Join-Path $env:LOCALAPPDATA "dotfiles\flat2vr"
$downloadRoot = Join-Path $stateRoot "downloads"
$shortcutRoot = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\VR Games"

$bepInEx = [ordered]@{
	Name = "BepInExPack Valheim 5.4.2333"
	File = "denikson-BepInExPack_Valheim-5.4.2333.zip"
	Url = "https://thunderstore.io/package/download/denikson/BepInExPack_Valheim/5.4.2333/"
	Sha256 = "5DD24CCBCAA9260F714B200F23C4C15547E2AA5F06906CAFCC0DEE56DB1BF716"
}
$vhvr = [ordered]@{
	Name = "VHVR 0.9.21"
	File = "vhvr-0.9.21.zip"
	Url = "https://github.com/brandonmousseau/vhvr-mod/releases/download/v0.9.21/vhvr-0.9.21.zip"
	Sha256 = "DF4569977A8052E6F86272AAB2F89D0DF93C31DE9A5024248F090DCAFEAE6EF8"
}
$portal2Vr = [ordered]@{
	Name = "Portal 2 VR 0.1.5"
	File = "Portal2VR-0.1.5.zip"
	Url = "https://github.com/Gistix/portal2vr/releases/download/v0.1.5/Portal2VR.zip"
	Sha256 = "8B89E958C08A27AC7177EA21C3B213982DF8273EBF7E0A36CAF983C5CB612C16"
}
$mccVr = [ordered]@{
	Name = "Halo MCC VR Alpha 0.3.3"
	File = "MCC_VR_ALPHA_0.3.3.zip"
	Url = "https://github.com/pancreations/Halo-MCC-VR/releases/download/MCC_VR_ALPHA_0.3.3/MCC_VR_ALPHA_0.3.3.zip"
	Sha256 = "C1CC84C1F2278E622F0A439E4DC3791A4E2264DEE8F1F71E48D61346D3AFE69D"
}

function Test-FileHash {
	param(
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][string]$Sha256
	)

	return (
		(Test-Path -LiteralPath $Path -PathType Leaf) -and
		((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Sha256)
	)
}

function Get-VerifiedAsset {
	param([Parameter(Mandatory)][Collections.IDictionary]$Asset)

	New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
	$path = Join-Path $downloadRoot $Asset.File
	if (Test-FileHash -Path $path -Sha256 $Asset.Sha256) {
		return $path
	}

	$partial = "$path.partial"
	Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
	Write-Host "Downloading $($Asset.Name)..."
	Invoke-WebRequest -UseBasicParsing -Uri $Asset.Url -OutFile $partial
	if (-not (Test-FileHash -Path $partial -Sha256 $Asset.Sha256)) {
		Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
		throw "$($Asset.Name) failed SHA-256 verification."
	}
	Move-Item -LiteralPath $partial -Destination $path -Force
	return $path
}

function Get-SteamGameDirectory {
	param(
		[Parameter(Mandatory)][string]$AppId,
		[Parameter(Mandatory)][string]$ExpectedName
	)

	$libraryFile = Join-Path $steamRoot "steamapps\libraryfolders.vdf"
	if (-not (Test-Path -LiteralPath $libraryFile -PathType Leaf)) {
		return $null
	}
	$libraries = [Collections.Generic.List[string]]::new()
	$libraries.Add($steamRoot)
	foreach ($match in [regex]::Matches([IO.File]::ReadAllText($libraryFile), '"path"\s+"([^"]+)"')) {
		$path = $match.Groups[1].Value.Replace("\\", "\")
		if (-not $libraries.Contains($path)) {
			$libraries.Add($path)
		}
	}

	foreach ($library in $libraries) {
		$manifest = Join-Path $library "steamapps\appmanifest_$AppId.acf"
		if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
			continue
		}
		$text = [IO.File]::ReadAllText($manifest)
		$installMatch = [regex]::Match($text, '"installdir"\s+"([^"]+)"')
		if (-not $installMatch.Success) {
			throw "Steam manifest $manifest does not contain an install directory."
		}
		$gameDirectory = Join-Path $library "steamapps\common\$($installMatch.Groups[1].Value)"
		if (-not (Test-Path -LiteralPath $gameDirectory -PathType Container)) {
			throw "$ExpectedName is registered in Steam but its game directory is missing: $gameDirectory"
		}
		return $gameDirectory
	}

	return $null
}

function Expand-VerifiedAsset {
	param(
		[Parameter(Mandatory)][Collections.IDictionary]$Asset,
		[Parameter(Mandatory)][scriptblock]$Install
	)

	$archive = Get-VerifiedAsset -Asset $Asset
	$staging = Join-Path $env:TEMP "dotfiles-flat2vr-$([guid]::NewGuid().ToString('N'))"
	New-Item -ItemType Directory -Path $staging -Force | Out-Null
	try {
		Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
		& $Install $staging
	} finally {
		Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
	}
}

function Copy-DirectoryContents {
	param(
		[Parameter(Mandatory)][string]$Source,
		[Parameter(Mandatory)][string]$Destination
	)

	New-Item -ItemType Directory -Path $Destination -Force | Out-Null
	Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}

function Set-Shortcut {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][string]$LaunchMode,
		[Parameter(Mandatory)][string]$IconPath
	)

	New-Item -ItemType Directory -Path $shortcutRoot -Force | Out-Null
	$shortcutPath = Join-Path $shortcutRoot "$Name.lnk"
	$shell = New-Object -ComObject WScript.Shell
	$shortcut = $shell.CreateShortcut($shortcutPath)
	$shortcut.TargetPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
	$shortcut.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Mode $LaunchMode"
	$shortcut.WorkingDirectory = $steamRoot
	$shortcut.IconLocation = "$IconPath,0"
	$shortcut.Save()
}

function Start-SteamVr {
	if (-not (Get-Process vrserver -ErrorAction SilentlyContinue)) {
		Start-Process -FilePath (Join-Path $steamRoot "steam.exe") -ArgumentList "-applaunch", "250820"
		$deadline = [DateTime]::UtcNow.AddSeconds(75)
		do {
			Start-Sleep -Milliseconds 500
			if (Get-Process vrserver -ErrorAction SilentlyContinue) {
				return
			}
		} while ([DateTime]::UtcNow -lt $deadline)
		throw "SteamVR did not become ready within 75 seconds."
	}
}

function Install-ValheimVr {
	param([Parameter(Mandatory)][string]$GameDirectory)

	$bepInExReady =
		(Test-FileHash -Path (Join-Path $GameDirectory "winhttp.dll") -Sha256 "93406D0A02E7C164B89828CBFE3B289930A112D2ECA50BD4A52E72ECE169E6A8") -and
		(Test-Path -LiteralPath (Join-Path $GameDirectory "BepInEx\core\BepInEx.dll") -PathType Leaf)
	if (-not $bepInExReady) {
		Expand-VerifiedAsset -Asset $bepInEx -Install {
			param($staging)
			Copy-DirectoryContents -Source (Join-Path $staging "BepInExPack_Valheim") -Destination $GameDirectory
		}
	}

	$vhvrReady =
		(Test-FileHash -Path (Join-Path $GameDirectory "BepInEx\plugins\ValheimVRMod.dll") -Sha256 "99FC2CA91A2D08FD6CBCD5908B99DA78544D121385547E33C6763A5516943A87") -and
		(Test-Path -LiteralPath (Join-Path $GameDirectory "Valheim_Data\Plugins\x86_64\XRSDKOpenVR.dll") -PathType Leaf)
	if (-not $vhvrReady) {
		Expand-VerifiedAsset -Asset $vhvr -Install {
			param($staging)
			Copy-DirectoryContents -Source $staging -Destination $GameDirectory
		}
	}

	if (-not $bepInExReady -or -not $vhvrReady) {
		Write-Host "Installed VHVR 0.9.21 for Valheim 0.221.12."
	} else {
		Write-Host "Valheim VHVR is current."
	}
	Set-Shortcut -Name "Valheim VR" -LaunchMode "LaunchValheim" -IconPath (Join-Path $GameDirectory "valheim.exe")
	Set-Shortcut -Name "Valheim (Flat Screen)" -LaunchMode "LaunchValheimFlat" -IconPath (Join-Path $GameDirectory "valheim.exe")
}

function Install-Portal2Vr {
	param([Parameter(Mandatory)][string]$GameDirectory)

	$ready =
		(Test-FileHash -Path (Join-Path $GameDirectory "bin\d3d9.dll") -Sha256 "E4D766A067FC4704EEC00D6D065BDE452A8A1BC424277C3D2F80FFA5F1CB578F") -and
		(Test-Path -LiteralPath (Join-Path $GameDirectory "VR\config.txt") -PathType Leaf)
	if (-not $ready) {
		Expand-VerifiedAsset -Asset $portal2Vr -Install {
			param($staging)
			Copy-DirectoryContents -Source $staging -Destination $GameDirectory
		}
		Write-Host "Installed Portal 2 VR 0.1.5."
	} else {
		Write-Host "Portal 2 VR is current."
	}
	Set-Shortcut -Name "Portal 2 VR" -LaunchMode "LaunchPortal2" -IconPath (Join-Path $GameDirectory "portal2.exe")
	Set-Shortcut -Name "Portal 2 (Flat Screen)" -LaunchMode "LaunchPortal2Flat" -IconPath (Join-Path $GameDirectory "portal2.exe")
}

function Install-MccVr {
	param([Parameter(Mandatory)][string]$GameDirectory)

	$modDirectory = Join-Path $GameDirectory "Halo_MCC_VR"
	$ready =
		(Test-FileHash -Path (Join-Path $modDirectory "halo3xr.dll") -Sha256 "44A82E28B65F8FD6D0A52FF2C87A55C37EFC8B5888DEE6836DEE9AEF89DE026D") -and
		(Test-FileHash -Path (Join-Path $modDirectory "halo3xr_launcher.exe") -Sha256 "930BEA232BFC3F8010BC2B385834DEBF796CD3DBEC02ECD0E8475E0DE8A72CE6") -and
		(Test-Path -LiteralPath (Join-Path $modDirectory "halomccvr.cfg") -PathType Leaf)
	if (-not $ready) {
		Expand-VerifiedAsset -Asset $mccVr -Install {
			param($staging)
			New-Item -ItemType Directory -Path $modDirectory -Force | Out-Null
			foreach ($name in "halo3xr.dll", "halo3xr_launcher.exe", "halomccvr.cfg", "LICENSE", "MANUAL-README.txt") {
				Copy-Item -LiteralPath (Join-Path $staging $name) -Destination $modDirectory -Force
			}
		}
		Write-Host "Installed Halo MCC VR Alpha 0.3.3."
	} else {
		Write-Host "Halo MCC VR is current."
	}
	Set-Shortcut -Name "Halo MCC VR" -LaunchMode "LaunchMcc" -IconPath (Join-Path $modDirectory "halo3xr_launcher.exe")
}

if ($Mode -ne "Ensure") {
	if ($Mode -in "LaunchValheim", "LaunchPortal2", "LaunchMcc") {
		Start-SteamVr
	}
	switch ($Mode) {
		"LaunchValheim" {
			Start-Process -FilePath (Join-Path $steamRoot "steam.exe") -ArgumentList "-applaunch", "892970"
		}
		"LaunchValheimFlat" {
			Start-Process -FilePath (Join-Path $steamRoot "steam.exe") -ArgumentList "-applaunch", "892970", "-ModEnabled=false"
		}
		"LaunchPortal2" {
			$arguments = @(
				"-applaunch", "620", "-insecure", "-window", "-novid",
				"+mat_motion_blur_percent_of_screen_max", "0", "+mat_queue_mode", "0",
				"+mat_vsync", "0", "+mat_antialias", "0", "+mat_grain_scale_override", "0",
				"-width", "1280", "-height", "720"
			)
			Start-Process -FilePath (Join-Path $steamRoot "steam.exe") -ArgumentList $arguments
		}
		"LaunchPortal2Flat" {
			$portalDirectory = Get-SteamGameDirectory -AppId "620" -ExpectedName "Portal 2"
			if (-not $portalDirectory) {
				throw "Portal 2 is not installed."
			}
			$hook = Join-Path $portalDirectory "bin\d3d9.dll"
			$disabledHook = "$hook.dotfiles-vr-disabled"
			if (Get-Process portal2 -ErrorAction SilentlyContinue) {
				throw "Portal 2 is already running."
			}
			Move-Item -LiteralPath $hook -Destination $disabledHook -Force
			try {
				Start-Process -FilePath (Join-Path $steamRoot "steam.exe") -ArgumentList "-applaunch", "620"
				$deadline = [DateTime]::UtcNow.AddSeconds(60)
				do {
					Start-Sleep -Milliseconds 500
					$portal = Get-Process portal2 -ErrorAction SilentlyContinue | Select-Object -First 1
				} while (-not $portal -and [DateTime]::UtcNow -lt $deadline)
				if (-not $portal) {
					throw "Portal 2 did not start within 60 seconds."
				}
				$portal.WaitForExit()
			} finally {
				if (Test-Path -LiteralPath $disabledHook -PathType Leaf) {
					Move-Item -LiteralPath $disabledHook -Destination $hook -Force
				}
			}
		}
		"LaunchMcc" {
			$mccDirectory = Get-SteamGameDirectory -AppId "976730" -ExpectedName "Halo: The Master Chief Collection"
			if (-not $mccDirectory) {
				throw "Halo: The Master Chief Collection is not installed."
			}
			Start-Process -FilePath (Join-Path $mccDirectory "Halo_MCC_VR\halo3xr_launcher.exe") -WorkingDirectory (Join-Path $mccDirectory "Halo_MCC_VR")
		}
	}
	return
}

if (-not (Test-Path -LiteralPath (Join-Path $steamRoot "steam.exe") -PathType Leaf)) {
	Write-Warning "Steam is not installed; skipping flat-to-VR mod reconciliation."
	return
}

$valheimDirectory = Get-SteamGameDirectory -AppId "892970" -ExpectedName "Valheim"
if ($valheimDirectory) {
	Install-ValheimVr -GameDirectory $valheimDirectory
} else {
	Write-Warning "Valheim is not installed; skipping VHVR."
}

$portal2Directory = Get-SteamGameDirectory -AppId "620" -ExpectedName "Portal 2"
if ($portal2Directory) {
	Install-Portal2Vr -GameDirectory $portal2Directory
} else {
	Write-Warning "Portal 2 is not installed; skipping Portal 2 VR."
}

$mccDirectory = Get-SteamGameDirectory -AppId "976730" -ExpectedName "Halo: The Master Chief Collection"
if ($mccDirectory) {
	Install-MccVr -GameDirectory $mccDirectory
} else {
	Write-Warning "Halo: The Master Chief Collection is not installed; skipping Halo MCC VR."
}

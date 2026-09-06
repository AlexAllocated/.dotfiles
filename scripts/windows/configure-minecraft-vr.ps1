param(
	[ValidateSet("Ensure", "Open")]
	[string]$Mode = "Ensure",
	[string]$PrismPath = "$env:LOCALAPPDATA\Programs\PrismLauncher\prismlauncher.exe",
	[string]$PrismRoot = "$env:APPDATA\PrismLauncher"
)

$ErrorActionPreference = "Stop"

$instanceName = "Vivecraft-26.2"
$minecraftVersion = "26.2"
$fabricVersion = "0.19.3"
$vivecraftVersion = "26.2-1.3.15-fabric"
$packVersion = "$vivecraftVersion-vr-water-first-dh-5"
$vivecraftFile = "vivecraft-26.2-1.3.15-fabric.jar"
$vivecraftUrl = "https://cdn.modrinth.com/data/wGoQDPN5/versions/VrqKDtZn/vivecraft-26.2-1.3.15-fabric.jar"
$vivecraftSha1 = "1cd59695918d538499457edddc11198ecfeb080d"
$vivecraftSha512 = "8f63a60587fd95b21884d2d61ac6e76f18a3e9a510226edbc0e06e4f276b8f84196bde314764aedf3bfc5f08499facd3bc3697ab97fa93602986fc6e8e7c7c7c"
$vivecraftSize = 6685183
$packRoot = Join-Path $env:LOCALAPPDATA "dotfiles\minecraft-vr"
$packPath = Join-Path $packRoot "Vivecraft-26.2.mrpack"
$graphicsLibrary = Join-Path $PSScriptRoot "minecraft-graphics-assets.ps1"
if (-not (Test-Path -LiteralPath $graphicsLibrary -PathType Leaf)) {
	throw "Minecraft graphics asset library is missing: $graphicsLibrary"
}
. $graphicsLibrary

function Set-JsonProperty {
	param(
		[Parameter(Mandatory)][psobject]$Object,
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)]$Value
	)

	if ($Object.PSObject.Properties.Name -contains $Name) {
		$Object.$Name = $Value
	} else {
		$Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
	}
}

function Set-LineSetting {
	param(
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][string]$Value,
		[string]$Separator = ":"
	)

	$lines = @(if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path } else { @() })
	$replacement = "$Name$Separator$Value"
	$found = $false
	$updated = foreach ($line in $lines) {
		if ($line -match "^$([regex]::Escape($Name))$([regex]::Escape($Separator))") {
			if (-not $found) {
				$replacement
				$found = $true
			}
		} else {
			$line
		}
	}
	if (-not $found) {
		$updated += $replacement
	}
	New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
	[IO.File]::WriteAllText($Path, (($updated -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

function Set-TomlSetting {
	param(
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][string]$Value
	)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return
	}
	$found = $false
	$updated = foreach ($line in Get-Content -LiteralPath $Path) {
		if ($line -match "^(\s*)$([regex]::Escape($Name))\s*=") {
			if (-not $found) {
				"$($Matches[1])$Name = $Value"
				$found = $true
			}
		} else {
			$line
		}
	}
	if (-not $found) {
		throw "Distant Horizons setting $Name was not found in $Path"
	}
	[IO.File]::WriteAllText($Path, (($updated -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

function Set-VivecraftPerformanceDefaults {
	param([Parameter(Mandatory)][string]$MinecraftRoot)

	# Use a 5080-tuned Medium+ profile at the Quest driver's native render target.
	# Preserve the important water, AA, and PBR effects while avoiding the shadow,
	# reflection, and lighting tiers that can push stereo rendering into ASW.
	Set-LineSetting -Path (Join-Path $MinecraftRoot "config\iris.properties") -Name "enableShaders" -Value "true" -Separator "="
	Set-LineSetting -Path (Join-Path $MinecraftRoot "options.txt") -Name "enableVsync" -Value "false"
	Set-LineSetting -Path (Join-Path $MinecraftRoot "options.txt") -Name "renderDistance" -Value "12"
	Set-LineSetting -Path (Join-Path $MinecraftRoot "options.txt") -Name "simulationDistance" -Value "8"
	Set-LineSetting -Path (Join-Path $MinecraftRoot "options.txt") -Name "entityDistanceScaling" -Value "0.85"
	Set-LineSetting -Path (Join-Path $MinecraftRoot "options.txt") -Name "particles" -Value "1"
	$shaderOptions = Join-Path $MinecraftRoot "shaderpacks\$MinecraftShaderPack.txt"
	foreach ($setting in ([ordered]@{
		SHADOW_QUALITY = "1"
		shadowDistance = "96.0"
		WATER_REFLECT_QUALITY = "2"
		BLOCK_REFLECT_QUALITY = "1"
		LIGHTSHAFT_QUALI_DEFINE = "1"
		SSAO_QUALI_DEFINE = "2"
		FXAA_DEFINE = "1"
		DETAIL_QUALITY = "2"
		CLOUD_QUALITY = "2"
		ANISOTROPIC_FILTER = "8"
		COLORED_LIGHTING = "0"
		WORLD_SPACE_REFLECTIONS = "-1"
		ENTITY_SHADOW = "-1"
		RP_MODE = "3"
		POM = "false"
		POM_QUALITY = "32"
		POM_DISTANCE = "12"
	}).GetEnumerator()) {
		Set-LineSetting -Path $shaderOptions -Name $setting.Key -Value $setting.Value -Separator "="
	}

	# Bring back the distant vista without restoring DH's original 256-chunk,
	# full-block-detail, 16-worker load. These settings retain a large horizon
	# while sharply limiting steady geometry and background generation pressure.
	$dhConfig = Join-Path $MinecraftRoot "config\DistantHorizons.toml"
	Set-TomlSetting -Path $dhConfig -Name "lodChunkRenderDistanceRadius" -Value "128"
	Set-TomlSetting -Path $dhConfig -Name "maxHorizontalResolution" -Value '"TWO_BLOCKS"'
	Set-TomlSetting -Path $dhConfig -Name "vanillaFadeMode" -Value '"SINGLE_PASS"'
	Set-TomlSetting -Path $dhConfig -Name "lodBiomeBlending" -Value "1"
	Set-TomlSetting -Path $dhConfig -Name "numberOfThreads" -Value "6"
	Set-TomlSetting -Path $dhConfig -Name "threadRunTimeRatio" -Value '"0.5"'

	$vivecraftPath = Join-Path $MinecraftRoot "config\vivecraft-client-config.json"
	if (Test-Path -LiteralPath $vivecraftPath -PathType Leaf) {
		$vivecraft = Get-Content -LiteralPath $vivecraftPath -Raw | ConvertFrom-Json
		Set-JsonProperty -Object $vivecraft -Name "useFsaa" -Value "false"
		Set-JsonProperty -Object $vivecraft -Name "renderScaleFactor" -Value "1.0"
		[IO.File]::WriteAllText(
			$vivecraftPath,
			(($vivecraft | ConvertTo-Json -Depth 20) + "`n"),
			[Text.UTF8Encoding]::new($false)
		)
	}
}

function Set-SteamVrPerformanceDefaults {
	$steamVrPath = Join-Path ${env:ProgramFiles(x86)} "Steam\config\steamvr.vrsettings"
	if (-not (Test-Path -LiteralPath $steamVrPath -PathType Leaf)) {
		Write-Warning "SteamVR settings do not exist yet: $steamVrPath"
		return
	}
	$settings = Get-Content -LiteralPath $steamVrPath -Raw | ConvertFrom-Json
	if (-not $settings.steamvr) {
		$settings | Add-Member -NotePropertyName "steamvr" -NotePropertyValue ([pscustomobject]@{})
	}
	# SteamVR's automatic mode selects its 150% ceiling for the RTX 5080. Use
	# an explicit 100% target so stereo Minecraft has a predictable frame budget.
	Set-JsonProperty -Object $settings.steamvr -Name "supersampleManualOverride" -Value $true
	Set-JsonProperty -Object $settings.steamvr -Name "supersampleScale" -Value 1.0
	$temporary = "$steamVrPath.amps.tmp"
	[IO.File]::WriteAllText(
		$temporary,
		(($settings | ConvertTo-Json -Depth 20) + "`n"),
		[Text.UTF8Encoding]::new($false)
	)
	Move-Item -LiteralPath $temporary -Destination $steamVrPath -Force
}

$vivecraftFileEntry = [ordered]@{
	path = "mods/$vivecraftFile"
	hashes = [ordered]@{
		sha1 = $vivecraftSha1
		sha512 = $vivecraftSha512
	}
	env = [ordered]@{
		client = "required"
		server = "unsupported"
	}
	downloads = @($vivecraftUrl)
	fileSize = $vivecraftSize
}

if (-not (Test-Path -LiteralPath $PrismPath -PathType Leaf)) {
	throw "Prism Launcher is missing: $PrismPath"
}

$existingInstance = Get-ChildItem (Join-Path $PrismRoot "instances") -Directory -ErrorAction SilentlyContinue |
	Where-Object {
		$configPath = Join-Path $_.FullName "instance.cfg"
		(Test-Path -LiteralPath $configPath) -and
		((Get-Content -LiteralPath $configPath -Raw) -match "(?m)^name=$([regex]::Escape($instanceName))\s*$")
	} |
	Select-Object -First 1

if (-not $existingInstance) {
	New-Item -ItemType Directory -Path $packRoot -Force | Out-Null
	$stagingRoot = Join-Path $env:TEMP "dotfiles-vivecraft-$([guid]::NewGuid().ToString('N'))"
	New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
	try {
		$index = [ordered]@{
			formatVersion = 1
			game = "minecraft"
			versionId = $packVersion
			name = $instanceName
			summary = "Pinned native-refresh Vivecraft profile with an optional full graphics library and performance mods"
			files = @($vivecraftFileEntry) + $MinecraftGraphicsFiles
			dependencies = [ordered]@{
				minecraft = $minecraftVersion
				"fabric-loader" = $fabricVersion
			}
		}
		$indexPath = Join-Path $stagingRoot "modrinth.index.json"
		[IO.File]::WriteAllText(
			$indexPath,
			($index | ConvertTo-Json -Depth 10),
			[Text.UTF8Encoding]::new($false)
		)
		Set-MinecraftGraphicsDefaults -MinecraftRoot (Join-Path $stagingRoot "overrides")
		Set-VivecraftPerformanceDefaults -MinecraftRoot (Join-Path $stagingRoot "overrides")
		Remove-Item -LiteralPath $packPath -Force -ErrorAction SilentlyContinue
		Compress-Archive -Path (Join-Path $stagingRoot "*") -DestinationPath "$packPath.zip" -Force
		Move-Item -LiteralPath "$packPath.zip" -Destination $packPath -Force
	} finally {
		Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
	}
	Write-Host "Generated pinned Vivecraft pack at $packPath."
	Start-Process -FilePath $PrismPath -ArgumentList @("--import", "`"$packPath`"")
	Write-Host "Prism Launcher is importing $instanceName; complete its first-run and Microsoft account prompts."
	exit 0
}

Write-Host "$instanceName already exists at $($existingInstance.FullName)."
Set-MinecraftInstanceMemory -InstanceRoot $existingInstance.FullName
$minecraftRoot = Join-Path $existingInstance.FullName "minecraft"
Sync-MinecraftGraphicsFiles -MinecraftRoot $minecraftRoot -SkipSettings
Set-VivecraftPerformanceDefaults -MinecraftRoot $minecraftRoot
Set-SteamVrPerformanceDefaults
if ($Mode -eq "Open") {
	Start-Process -FilePath $PrismPath -ArgumentList @("--show", "`"$($existingInstance.Name)`"")
}

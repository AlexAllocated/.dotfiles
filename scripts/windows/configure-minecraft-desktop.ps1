param(
	[ValidateSet("Ensure", "Open")]
	[string]$Mode = "Ensure",
	[string]$PrismPath = "$env:LOCALAPPDATA\Programs\PrismLauncher\prismlauncher.exe",
	[string]$PrismRoot = "$env:APPDATA\PrismLauncher"
)

$ErrorActionPreference = "Stop"

$instanceName = "Minecraft-26.2-RTX-style"
$minecraftVersion = "26.2"
$fabricVersion = "0.19.3"
$packVersion = "26.2-rtx-style-4"
$packRoot = Join-Path $env:LOCALAPPDATA "dotfiles\minecraft-desktop"
$packPath = Join-Path $packRoot "Minecraft-26.2-RTX-style.mrpack"

$graphicsLibrary = Join-Path $PSScriptRoot "minecraft-graphics-assets.ps1"
if (-not (Test-Path -LiteralPath $graphicsLibrary -PathType Leaf)) {
	throw "Minecraft graphics asset library is missing: $graphicsLibrary"
}
. $graphicsLibrary

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
	$stagingRoot = Join-Path $env:TEMP "dotfiles-minecraft-desktop-$([guid]::NewGuid().ToString('N'))"
	New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
	try {
		$index = [ordered]@{
			formatVersion = 1
			game = "minecraft"
			versionId = $packVersion
			name = $instanceName
			summary = "Pinned high-end desktop profile with shaders, PBR, emissive textures, extended view distance, animation, sound, and performance mods"
			files = $MinecraftGraphicsFiles
			dependencies = [ordered]@{
				minecraft = $minecraftVersion
				"fabric-loader" = $fabricVersion
			}
		}
		[IO.File]::WriteAllText(
			(Join-Path $stagingRoot "modrinth.index.json"),
			($index | ConvertTo-Json -Depth 10),
			[Text.UTF8Encoding]::new($false)
		)

		Set-MinecraftGraphicsDefaults -MinecraftRoot (Join-Path $stagingRoot "overrides")

		Remove-Item -LiteralPath $packPath -Force -ErrorAction SilentlyContinue
		Compress-Archive -Path (Join-Path $stagingRoot "*") -DestinationPath "$packPath.zip" -Force
		Move-Item -LiteralPath "$packPath.zip" -Destination $packPath -Force
	} finally {
		Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
	}
	Write-Host "Generated pinned desktop graphics pack at $packPath."
	Start-Process -FilePath $PrismPath -ArgumentList @("--import", "`"$packPath`"")
	Write-Host "Prism Launcher is importing $instanceName."
	exit 0
}

Write-Host "$instanceName already exists at $($existingInstance.FullName)."
Set-MinecraftInstanceMemory -InstanceRoot $existingInstance.FullName
Sync-MinecraftGraphicsFiles -MinecraftRoot (Join-Path $existingInstance.FullName "minecraft")
if ($Mode -eq "Open") {
	Start-Process -FilePath $PrismPath -ArgumentList @("--show", "`"$($existingInstance.Name)`"")
}

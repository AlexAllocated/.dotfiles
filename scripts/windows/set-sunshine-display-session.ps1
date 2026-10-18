param(
	[ValidateSet("Start", "Stop")]
	[string]$Mode = "Start",
	[int]$Width = 2732,
	[int]$Height = 2048,
	[int]$RefreshRate = 120,
	[string]$WallpaperScriptPath = "$env:LOCALAPPDATA\dotfiles\configure-wallpapers.ps1"
)

$ErrorActionPreference = "Stop"
Write-Host "Sunshine owns virtual-display activation and disconnect restoration."
if (Test-Path -LiteralPath $WallpaperScriptPath -PathType Leaf) {
	& $WallpaperScriptPath -Mode Apply
}

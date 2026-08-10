param(
	[Parameter(Mandatory = $true)]
	[string]$DriverDirectory,

	[Parameter(Mandatory = $true)]
	[string]$SettingsPath,

	[string]$ConfigurationDirectory = "C:\VirtualDisplayDriver"
)

$ErrorActionPreference = "Stop"

$logDirectory = Join-Path $env:LOCALAPPDATA "dotfiles\virtual-display"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$logPath = Join-Path $logDirectory "install.log"
Start-Transcript -Path $logPath -Force | Out-Null

trap {
	Write-Error $_
	Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
	exit 1
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	throw "Virtual Display Driver installation requires an elevated Windows PowerShell."
}

$infPath = Join-Path $DriverDirectory "MttVDD.inf"
$catalogPath = Join-Path $DriverDirectory "mttvdd.cat"
$packageDirectory = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $DriverDirectory))
$devconPath = Join-Path $packageDirectory "Dependencies\devcon.exe"

foreach ($requiredPath in @($infPath, $catalogPath, $devconPath, $SettingsPath)) {
	if (-not (Test-Path -LiteralPath $requiredPath)) {
		throw "Required Virtual Display Driver file is missing: $requiredPath"
	}
}

$catalogSignature = Get-AuthenticodeSignature -LiteralPath $catalogPath
if ($catalogSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
	throw "Virtual Display Driver catalog signature is not valid: $($catalogSignature.StatusMessage)"
}
$devconSignature = Get-AuthenticodeSignature -LiteralPath $devconPath
if (
	$devconSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
	$devconSignature.SignerCertificate.Subject -notlike "CN=Microsoft Corporation,*"
) {
	throw "The bundled Device Console is not validly signed by Microsoft."
}

New-Item -ItemType Directory -Path $ConfigurationDirectory -Force | Out-Null
$configurationPath = Join-Path $ConfigurationDirectory "vdd_settings.xml"
if (
	[System.IO.Path]::GetFullPath($SettingsPath) -ne
	[System.IO.Path]::GetFullPath($configurationPath)
) {
	Copy-Item -LiteralPath $SettingsPath -Destination $configurationPath -Force
}

$registryPath = "HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver"
New-Item -Path $registryPath -Force | Out-Null
Set-ItemProperty -Path $registryPath -Name "VDDPATH" -Type String -Value $ConfigurationDirectory

Get-Process -Name "VDD Control" -ErrorAction SilentlyContinue | Stop-Process -Force

$device = Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue |
	Where-Object FriendlyName -EQ "Virtual Display Driver" |
	Select-Object -First 1

if ($device) {
	Write-Host "Restarting the existing Virtual Display Driver device..."
	& pnputil.exe /restart-device $device.InstanceId
} else {
	Write-Host "Installing the signed Virtual Display Driver device..."
	& $devconPath install $infPath "Root\MttVDD"
}

$devconExitCode = $LASTEXITCODE
if ($devconExitCode -notin @(0, 1)) {
	throw "Device Console failed with exit code $devconExitCode."
}

Start-Sleep -Seconds 5
$installedDevice = Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue |
	Where-Object FriendlyName -EQ "Virtual Display Driver" |
	Select-Object -First 1
if (-not $installedDevice -or $installedDevice.Status -ne "OK") {
	throw "The Virtual Display Driver did not become healthy after installation."
}

Write-Host "Virtual Display Driver is installed and uses $ConfigurationDirectory\vdd_settings.xml."
if ($devconExitCode -eq 1) {
	Write-Warning "Windows reported that a reboot is required."
}

Stop-Transcript | Out-Null

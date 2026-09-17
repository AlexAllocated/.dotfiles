param([switch]$Disable)

$ErrorActionPreference = 'Stop'
if (-not $Disable) { throw 'Specify -Disable to apply this policy.' }
$policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
if ((Get-ItemPropertyValue -LiteralPath $policyPath -Name DisableSR -ErrorAction SilentlyContinue) -eq 1) {
	Write-Host 'System Restore is already disabled.'
	exit 0
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	$arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Disable' -f $PSCommandPath
	$process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
	if ($process.ExitCode -ne 0) { throw "System Restore policy failed: $($process.ExitCode)" }
	exit 0
}
Disable-ComputerRestore -Drive "$env:SystemDrive\"
New-Item -Path $policyPath -Force | Out-Null
New-ItemProperty -LiteralPath $policyPath -Name DisableSR -PropertyType DWord -Value 1 -Force | Out-Null
Write-Host 'Disabled System Restore.'

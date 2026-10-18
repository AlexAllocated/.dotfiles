$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'configure-sunshine-virtual-display.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function = $ast.Find({
	param($node)
	$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SunshineAdaptiveDisplaySettings'
}, $true)
. ([scriptblock]::Create($function.Extent.Text))
$fixture = [IO.Path]::GetTempFileName()
try {
	[IO.File]::WriteAllText($fixture, 'old build')
	$rejected = $false
	try { Get-SunshineAdaptiveDisplaySettings $fixture '{virtual}' } catch { $rejected = $true }
	if (-not $rejected) { throw 'Unsupported binary was accepted.' }
	[IO.File]::WriteAllText($fixture, 'binary fixture preferred_output_name')
	$settings = Get-SunshineAdaptiveDisplaySettings $fixture '{virtual}'
	$second = Get-SunshineAdaptiveDisplaySettings $fixture '{virtual}'
	if (($settings | ConvertTo-Json) -cne ($second | ConvertTo-Json)) { throw 'Second reconciliation changed the policy.' }
	if ($settings.output_name -ne '{virtual}' -or $settings.preferred_output_name -ne '') { throw 'Wrong output policy.' }
	if ($settings.dd_configuration_option -ne 'ensure_active') { throw 'The virtual display must not replace the primary monitor.' }
	foreach ($key in @('dd_resolution_option', 'dd_refresh_rate_option', 'dd_hdr_option')) {
		if ($settings[$key] -ne 'auto') { throw "$key must follow the client for the VDD." }
	}
	if ($settings.dd_config_revert_on_disconnect -ne 'enabled') { throw 'Disconnect restoration is disabled.' }
	Write-Host 'PASS: unsupported binary rejected, VDD selected without replacing the primary monitor, restoration retained.'
} finally {
	Remove-Item -LiteralPath $fixture
}

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'configure-sunshine-virtual-display.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function = $ast.Find({
	param($node)
	$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SunshineSignInApplicationsJson'
}, $true)
if (-not $function) { throw 'The sign-in application reconciler is missing.' }
. ([scriptblock]::Create($function.Extent.Text))

$fixture = '{"env":{"custom":"preserve"},"apps":[{"name":"Desktop","image-path":"desktop.png"},{"name":"Game","cmd":"game.exe","prep-cmd":[{"do":"prepare","undo":"restore","elevated":true}]}]}'
$first = Get-SunshineSignInApplicationsJson $fixture
$result = $first | ConvertFrom-Json
$original = $fixture | ConvertFrom-Json
if ($result.apps.Count -ne 3) { throw 'The recovery application was not appended.' }
if ($result.env.custom -ne 'preserve') { throw 'Application environment changed.' }
for ($index = 0; $index -lt 2; $index++) {
	if (($result.apps[$index] | ConvertTo-Json -Depth 20) -cne ($original.apps[$index] | ConvertTo-Json -Depth 20)) {
		throw 'An existing application changed.'
	}
}
if ($result.apps[2].'exclude-global-prep-cmd' -ne $true) { throw 'The recovery application still uses global commands.' }
if ((Get-SunshineSignInApplicationsJson $first) -cne $first) { throw 'Second reconciliation changed the application list.' }

$updated = Get-SunshineSignInApplicationsJson '{"apps":[{"name":"Windows Sign-In","exclude-global-prep-cmd":false,"image-path":"custom.png"}]}' | ConvertFrom-Json
if ($updated.apps[0].'exclude-global-prep-cmd' -ne $true -or $updated.apps[0].'image-path' -ne 'custom.png') {
	throw 'Existing recovery application reconciliation failed.'
}
foreach ($invalid in @(
	'{"apps":[{"name":"Windows Sign-In","cmd":"custom.exe"}]}',
	'{"apps":[{"name":"Windows Sign-In","prep-cmd":[{"do":"custom"}]}]}',
	'{"apps":[{"name":"Windows Sign-In","detached":["custom.exe"]}]}',
	'{"apps":[{"name":"Windows Sign-In"},{"name":"Windows Sign-In"}]}',
	'{"env":{}}'
)) {
	$rejected = $false
	try { Get-SunshineSignInApplicationsJson $invalid | Out-Null } catch { $rejected = $true }
	if (-not $rejected) { throw 'A conflicting or invalid configuration was accepted.' }
}
$source = Get-Content -LiteralPath $sourcePath -Raw
if ($source -notmatch 'dd_configuration_option = "ensure_primary"') { throw 'Physical displays can still be disabled by streaming.' }
if ($source -notmatch 'global_prep_cmd = \$globalPrepCommand') { throw 'Normal streaming lost its NVIDIA frame limit.' }
Write-Host 'PASS: recovery access, existing apps preserved, conflicts rejected, second pass unchanged, physical displays retained.'

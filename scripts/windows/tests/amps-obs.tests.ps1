$ErrorActionPreference = 'Stop'
# Load only the pure reconciler, not OBS's installation/provisioning side effects.
$path = Join-Path $PSScriptRoot '..\configure-obs.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Add-MissingObsAudioDevices' }, $true)
. ([scriptblock]::Create($function.Extent.Text))
$existing = [pscustomobject]@{ name='My custom media label'; uuid='source-uuid'; settings=@{device_id='unchanged-endpoint'}; volume=0.42 }
$scene = [pscustomobject]@{ AuxAudioDevice4=$existing }
$before = $existing | ConvertTo-Json -Depth 5 -Compress
$defaults = @{ AuxAudioDevice4=@{ name='AMPS Media'; settings=@{device_id='other-id'} }; AuxAudioDevice1=@{ name='AMPS Clean Mic' } }
Add-MissingObsAudioDevices -SceneCollection $scene -Devices $defaults
if (($scene.AuxAudioDevice4 | ConvertTo-Json -Depth 5 -Compress) -cne $before) { throw 'Existing OBS source changed' }
if ($scene.AuxAudioDevice1.name -ne 'AMPS Clean Mic') { throw 'Missing source was not provisioned' }
$once = $scene | ConvertTo-Json -Depth 5 -Compress
Add-MissingObsAudioDevices -SceneCollection $scene -Devices $defaults
if (($scene | ConvertTo-Json -Depth 5 -Compress) -cne $once) { throw 'Repeated apply changed OBS sources' }
Write-Host 'PASS: OBS preserves source identity, bindings, custom labels and levels; fresh sources use AMPS; repeat is unchanged.'

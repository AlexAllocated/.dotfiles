$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\amps-migration.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }

# Simulate tasks/processes/endpoint policy; never touch the live Windows graph.
function Get-ScheduledTask($TaskName) { return $script:tasks[$TaskName] }
function Export-ScheduledTask($TaskName) { return ($script:tasks[$TaskName] | ConvertTo-Json -Depth 5 -Compress) }
function Register-ScheduledTask($TaskName, $Xml, [switch]$Force) { $script:tasks[$TaskName] = $Xml | ConvertFrom-Json }
function Unregister-ScheduledTask($TaskName, [switch]$Confirm) { $script:tasks.Remove($TaskName) }
function Stop-ScheduledTask($TaskName) { $script:tasks[$TaskName].State = 'Ready' }
function Start-ScheduledTask($TaskName) { $script:tasks[$TaskName].State = 'Running' }
function Disable-ScheduledTask($TaskName) { $script:tasks[$TaskName].Enabled = $false }
function Get-Process($Name) { return @() }
function Get-VacEndpoints { return $script:endpoints }
function Restore-AmpsEndpointNames($Path) { $script:endpoints = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('amps-migration-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Initialize-Fixture($Name, $Mode) {
   $script:applicationRoot = Join-Path $testRoot "$Name\local\AMPS"
   $script:legacyRoot = Join-Path $testRoot "$Name\local\AudioArray"
   $script:configRoot = Join-Path $testRoot "$Name\roaming\AMPS"
   $script:legacyConfigRoot = Join-Path $testRoot "$Name\roaming\AudioArray"
   $script:binaryRoot = Join-Path $applicationRoot 'bin'
   $script:binaryPath = Join-Path $binaryRoot 'amps.exe'
   $script:uiBinaryPath = Join-Path $binaryRoot 'amps-ui.exe'
   $script:configPath = Join-Path $configRoot 'config.toml'
   $script:stampPath = Join-Path $applicationRoot 'source.sha256'
   $script:shortcutRoot = Join-Path $testRoot "$Name\shortcuts"
   $script:webStoragePath = Join-Path $testRoot "$Name\web-storage"
   New-Item -ItemType Directory -Path $webStoragePath -Force | Out-Null
   'chart positions and sound preferences' | Set-Content (Join-Path $webStoragePath '000003.log')
   New-Item -ItemType Directory -Path $configRoot, $binaryRoot, $shortcutRoot -Force | Out-Null
   $script:tasks = @{}
   $script:endpoints = foreach ($direction in @('Render','Capture')) {
      foreach ($cable in 1..7) { [pscustomobject]@{ Cable=$cable; Direction=$direction; Name="AudioArray test $cable"; ItemId="test-$direction-$cable" } }
   }
   if ($Mode -ne 'fresh') {
      New-Item -ItemType Directory -Path $legacyConfigRoot, (Join-Path $legacyRoot 'bin') -Force | Out-Null
      'legacy config' | Set-Content (Join-Path $legacyConfigRoot 'config.toml')
      'custom routes and revision 12' | Set-Content (Join-Path $legacyConfigRoot 'controls.toml')
      'AirPods history' | Set-Content (Join-Path $legacyConfigRoot 'physical-endpoints.toml')
      New-Item -ItemType Directory -Path (Join-Path $legacyConfigRoot 'control-v1') | Out-Null
      'stale request' | Set-Content (Join-Path $legacyConfigRoot 'control-v1\request.json')
      'old engine' | Set-Content (Join-Path $legacyRoot 'bin\audioarray.exe')
      'old UI' | Set-Content (Join-Path $legacyRoot 'bin\audioarray-ui.exe')
      'old shortcut' | Set-Content (Join-Path $shortcutRoot 'AudioArray.lnk')
      $script:tasks.AudioArray = [pscustomobject]@{ Actions=@([pscustomobject]@{Execute=(Join-Path $legacyRoot 'bin\audioarray-ui.exe')}); State='Running'; Enabled=$true }
   }
   if ($Mode -eq 'existing') {
      'new config wins' | Set-Content $configPath
      'new custom routes' | Set-Content (Join-Path $configRoot 'controls.toml')
      'old AMPS engine' | Set-Content $binaryPath
      'old AMPS UI' | Set-Content $uiBinaryPath
      'old source hash' | Set-Content $stampPath
      $script:tasks.AMPS = [pscustomobject]@{ Actions=@([pscustomobject]@{Execute=$uiBinaryPath}); State='Running'; Enabled=$true }
   }
}

foreach ($mode in @('legacy', 'existing', 'fresh')) {
   Initialize-Fixture -Name "rollback-$mode" -Mode $mode
   $expected = Get-AmpsStateSource -Current $configRoot -Legacy $legacyConfigRoot
   $backup = Start-AmpsDeployment
   Initialize-AmpsDeploymentState -Backup $backup
   if ($mode -eq 'legacy') {
      Assert ((Get-Content (Join-Path $configRoot 'controls.toml')) -eq 'custom routes and revision 12') 'Lost legacy controls'
      Assert ((Get-Content (Join-Path $configRoot 'physical-endpoints.toml')) -eq 'AirPods history') 'Lost device history'
      Assert (-not (Test-Path (Join-Path $configRoot 'control-v1'))) 'Migrated stale mailbox'
   }
   if ($mode -eq 'existing') { Assert ((Get-Content $configPath) -eq 'new config wins') 'Overwrote existing AMPS state' }
   'replacement config' | Set-Content $configPath
   'replacement engine' | Set-Content $binaryPath
   'replacement UI' | Set-Content $uiBinaryPath
   'replacement hash' | Set-Content $stampPath
   'replacement shortcut' | Set-Content (Join-Path $shortcutRoot 'AMPS.lnk')
   $script:tasks.AMPS = [pscustomobject]@{ Actions=@([pscustomobject]@{Execute=$uiBinaryPath}); State='Running'; Enabled=$true }
   foreach ($endpoint in $script:endpoints) { $endpoint.Name = 'AMPS changed' }
   # Inject a failure after all migration side effects, before verification.
   Restore-AmpsDeployment -Backup $backup
   Assert ((Get-Content (Join-Path $webStoragePath '000003.log')) -eq 'chart positions and sound preferences') 'Browser preferences not restored'
   Assert (@($script:endpoints | Where-Object Name -eq 'AMPS changed').Count -eq 0) 'Rollback did not restore endpoint names'
   Assert (Test-Path (Join-Path $backup 'failed-state')) 'Failed state not retained'
   if ($mode -eq 'existing') {
      Assert ((Get-Content $configPath) -eq 'new config wins') 'Existing AMPS configuration not restored'
      Assert ((Get-Content $binaryPath) -eq 'old AMPS engine') 'Existing AMPS binary not restored'
      Assert ($script:tasks.AMPS.State -eq 'Running') 'Existing AMPS task not resumed'
   } else {
      Assert (-not (Test-Path $configPath)) 'Rollback left a new AMPS config authoritative'
      Assert (-not $script:tasks.ContainsKey('AMPS')) 'Rollback left a new startup entry'
   }
   if ($mode -ne 'fresh') {
      Assert ($script:tasks.AudioArray.Enabled -and $script:tasks.AudioArray.State -eq 'Running') 'Legacy startup not restored'
      Assert ((Get-Content (Join-Path $legacyConfigRoot 'controls.toml')) -eq 'custom routes and revision 12') 'Modified legacy preferences'
   }
}
Initialize-Fixture -Name 'success' -Mode 'legacy'
$backup = Start-AmpsDeployment
Initialize-AmpsDeploymentState -Backup $backup
Complete-AmpsDeployment -Backup $backup
Assert (-not $script:tasks.ContainsKey('AudioArray')) 'Legacy task not retired'
Assert (Test-Path (Join-Path $backup 'retired-AudioArray.lnk')) 'Old shortcut not recoverable'
Assert ((Get-AmpsStateSource -Current $configRoot -Legacy $legacyConfigRoot) -eq $configRoot) 'Repeat apply would re-import legacy state'
'changed by user' | Set-Content (Join-Path $configRoot 'controls.toml')
Assert ((Get-AmpsStateSource -Current $configRoot -Legacy $legacyConfigRoot) -eq $configRoot) 'User edits lost precedence'
Initialize-Fixture -Name 'partial' -Mode 'legacy'
'do not overwrite' | Set-Content (Join-Path $configRoot 'controls.toml')
$rejected = $false
try { Get-AmpsStateSource -Current $configRoot -Legacy $legacyConfigRoot | Out-Null } catch { $rejected = $true }
Assert $rejected 'Incomplete destination was silently overwritten'
Initialize-Fixture -Name 'fresh-success' -Mode 'fresh'
$example = Join-Path $testRoot 'example.toml'
$previous = Join-Path $applicationRoot 'config-base.toml'
[IO.File]::WriteAllText($example, 'new managed default')
$desired = Get-AmpsDesiredConfig -Current $configRoot -Legacy $legacyConfigRoot -Example $example -PreviousBase $previous
Assert ($desired -eq 'new managed default') 'Fresh setup did not select defaults'
$backup = Start-AmpsDeployment
Initialize-AmpsDeploymentState -Backup $backup
[IO.File]::WriteAllText($configPath, $desired)
Complete-AmpsDeployment -Backup $backup
Assert ((Get-AmpsStateSource -Current $configRoot -Legacy $legacyConfigRoot) -eq $configRoot) 'Fresh setup not authoritative'
[IO.File]::WriteAllText($configPath, 'custom AMPS routes')
Assert ((Get-AmpsDesiredConfig -Current $configRoot -Legacy $legacyConfigRoot -Example $example -PreviousBase $previous) -eq 'custom AMPS routes') 'Custom AMPS config overwritten'
[IO.File]::WriteAllText($previous, 'old managed default')
[IO.File]::WriteAllText($configPath, 'old managed default')
Assert ((Get-AmpsDesiredConfig -Current $configRoot -Legacy $legacyConfigRoot -Example $example -PreviousBase $previous) -eq 'new managed default') 'Managed base did not update'
Initialize-Fixture -Name 'custom-legacy' -Mode 'legacy'
[IO.File]::WriteAllText((Join-Path $legacyConfigRoot 'config.toml'), 'AudioArray Media; custom latency = 77')
Assert ((Get-AmpsDesiredConfig -Current $configRoot -Legacy $legacyConfigRoot -Example $example -PreviousBase $previous) -eq 'AMPS Media; custom latency = 77') 'Custom legacy config not preserved'
Write-Host "PASS: legacy/existing/fresh rollback and success, state precedence, config preservation, managed base update, partial-state rejection. Fixtures: $testRoot"

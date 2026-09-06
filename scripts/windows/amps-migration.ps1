# Deployment helpers shared by the reconciler and isolated migration tests.
# Runtime state is copied only while both managed supervisors are stopped.
function Get-AmpsStateSource {
   param([string]$Current, [string]$Legacy)
   if (Test-Path -LiteralPath (Join-Path $Current 'config.toml')) { return $Current }
   if (@(Get-ChildItem -LiteralPath $Current -File -ErrorAction SilentlyContinue).Count) {
      throw 'Incomplete AMPS state already exists; refusing to overwrite it with AudioArray state.'
   }
   if (Test-Path -LiteralPath (Join-Path $Legacy 'config.toml')) { return $Legacy }
   return $null
}

function Get-AmpsDesiredConfig {
   param([string]$Current, [string]$Legacy, [string]$Example, [string]$PreviousBase)
   $source = Get-AmpsStateSource -Current $Current -Legacy $Legacy
   $exampleText = [IO.File]::ReadAllText($Example)
   if (-not $source) { return $exampleText }
   $text = [IO.File]::ReadAllText((Join-Path $source 'config.toml'))
   if ($source -eq $Legacy) {
      # Only the old brand changes. Internal route keys and custom settings stay.
      return $text.Replace('AudioArray ', 'AMPS ')
   }
   if ((Test-Path -LiteralPath $PreviousBase) -and $text -ceq [IO.File]::ReadAllText($PreviousBase)) {
      return $exampleText
   }
   # A customized destination is authoritative, including on repeated applies.
   return $text
}

function Copy-AmpsPersistentState {
   param([string]$Source, [string]$Destination)
   if (-not $Source -or $Source -eq $Destination) { return }
   New-Item -ItemType Directory -Path $Destination -Force | Out-Null
   # The mailbox contains live-session requests/locks, not durable preferences.
   foreach ($entry in Get-ChildItem -LiteralPath $Source -Force) {
      if ($entry.Name -eq 'control-v1') { continue }
      $target = Join-Path $Destination $entry.Name
      if (Test-Path -LiteralPath $target) { throw "Refusing to overwrite existing AMPS state: $target" }
      Copy-Item -LiteralPath $entry.FullName -Destination $target -Recurse
   }
}

function Stop-AmpsManagedInstances {
   foreach ($name in @('AMPS', 'AudioArray')) {
      $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
      if ($task) { Stop-ScheduledTask -TaskName $name }
   }
   foreach ($path in @($uiBinaryPath, $binaryPath, (Join-Path $legacyRoot 'bin\audioarray-ui.exe'), (Join-Path $legacyRoot 'bin\audioarray.exe'))) {
      Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($path)) -ErrorAction SilentlyContinue |
         Where-Object { $_.Path -ieq $path } | Stop-Process -Force
   }
}

function Start-AmpsDeployment {
   $source = Get-AmpsStateSource -Current $configRoot -Legacy $legacyConfigRoot
   $backup = Join-Path $applicationRoot ('backups\deployment-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
   New-Item -ItemType Directory -Path $backup -Force | Out-Null
   $tasks = @()
   foreach ($name in @('AMPS', 'AudioArray')) {
      $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
      if (-not $task) { continue }
      $expectedExe = if ($name -eq 'AMPS') { $uiBinaryPath } else { Join-Path $legacyRoot 'bin\audioarray-ui.exe' }
      if ($task.Actions.Count -ne 1 -or $task.Actions[0].Execute -ine $expectedExe) {
         throw "Task $name does not belong to this managed installation."
      }
      $xml = Export-ScheduledTask -TaskName $name
      $xml | Set-Content -LiteralPath (Join-Path $backup "$name.task.xml") -Encoding UTF8
      $running = @((Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $expectedExe })).Count -gt 0
      $tasks += [pscustomobject]@{ Name = $name; Resume = ($task.State -eq 'Running' -or $running) }
   }
   @(Get-VacEndpoints) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backup 'endpoints.json') -Encoding UTF8
   $state = [pscustomobject]@{
      Source = $source
      CurrentState = (Test-Path -LiteralPath $configPath)
      CurrentBinaries = (Test-Path -LiteralPath $binaryPath)
      Tasks = $tasks
   }
   $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup 'deployment.json') -Encoding UTF8
   try {
      Stop-AmpsManagedInstances
      if ($source) { Copy-Item -LiteralPath $source -Destination (Join-Path $backup 'state') -Recurse }
      if ($webStoragePath -and (Test-Path -LiteralPath $webStoragePath)) {
         $storageBackup = Join-Path $backup 'web-storage'
         New-Item -ItemType Directory -Path $storageBackup | Out-Null
         Get-ChildItem -LiteralPath $webStoragePath -File | Where-Object Name -ne 'LOCK' |
            Copy-Item -Destination $storageBackup
      }
      foreach ($pair in @(@($binaryRoot, 'bin'), @((Join-Path $legacyRoot 'bin'), 'legacy-bin'))) {
         if (Test-Path -LiteralPath $pair[0]) { Copy-Item -LiteralPath $pair[0] -Destination (Join-Path $backup $pair[1]) -Recurse }
      }
      foreach ($metadata in @($stampPath, (Join-Path $applicationRoot 'config-base.toml'))) {
         if (Test-Path -LiteralPath $metadata) { Copy-Item -LiteralPath $metadata -Destination $backup }
      }
      foreach ($name in @('AMPS', 'AudioArray')) {
         $shortcut = Join-Path $shortcutRoot "$name.lnk"
         if (Test-Path -LiteralPath $shortcut) { Copy-Item -LiteralPath $shortcut -Destination $backup }
      }
   } catch {
      # No managed configuration/names have changed yet; resume the old owner.
      foreach ($task in $tasks) { if ($task.Resume) { Start-ScheduledTask -TaskName $task.Name } }
      throw
   }
   return $backup
}

function Initialize-AmpsDeploymentState {
   param([string]$Backup)
   $state = Get-Content -LiteralPath (Join-Path $Backup 'deployment.json') -Raw | ConvertFrom-Json
   if ($state.Source -and $state.Source -ne $configRoot) {
      Copy-AmpsPersistentState -Source (Join-Path $Backup 'state') -Destination $configRoot
      Write-Host 'Migrated AudioArray preferences to AMPS; the original and a recovery snapshot are retained.'
   }
   $task = Get-ScheduledTask -TaskName AudioArray -ErrorAction SilentlyContinue
   if ($task) { Disable-ScheduledTask -TaskName AudioArray | Out-Null }
}

function Restore-AmpsEndpointNames {
   param([string]$Path)
   $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$endpointConfiguratorSource`"", '-RestoreNamesPath', "`"$Path`""
   ) -NoNewWindow -PassThru
   $null = $process.Handle
   $process.WaitForExit(); $process.Refresh()
   if ($process.ExitCode -ne 0) { throw 'Could not restore the original endpoint names; recovery snapshot is retained.' }
}

function Restore-AmpsDeployment {
   param([string]$Backup)
   $state = Get-Content -LiteralPath (Join-Path $Backup 'deployment.json') -Raw | ConvertFrom-Json
   Stop-AmpsManagedInstances
   if ($webStoragePath -and (Test-Path -LiteralPath (Join-Path $Backup 'web-storage'))) {
      if (Test-Path -LiteralPath $webStoragePath) { Move-Item -LiteralPath $webStoragePath -Destination (Join-Path $Backup 'failed-web-storage') }
      Copy-Item -LiteralPath (Join-Path $Backup 'web-storage') -Destination $webStoragePath -Recurse
   }
   # Keep failed files for diagnosis instead of deleting the new installation.
   if (Test-Path -LiteralPath $configRoot) { Move-Item -LiteralPath $configRoot -Destination (Join-Path $Backup 'failed-state') }
   if (Test-Path -LiteralPath $binaryRoot) { Move-Item -LiteralPath $binaryRoot -Destination (Join-Path $Backup 'failed-bin') }
   if ($state.CurrentState) { Copy-Item -LiteralPath (Join-Path $Backup 'state') -Destination $configRoot -Recurse }
   if ($state.CurrentBinaries) { Copy-Item -LiteralPath (Join-Path $Backup 'bin') -Destination $binaryRoot -Recurse }
   foreach ($metadata in @($stampPath, (Join-Path $applicationRoot 'config-base.toml'))) {
      $name = Split-Path $metadata -Leaf
      if (Test-Path -LiteralPath $metadata) { Move-Item -LiteralPath $metadata -Destination (Join-Path $Backup "failed-$name") }
      if (Test-Path -LiteralPath (Join-Path $Backup $name)) { Copy-Item -LiteralPath (Join-Path $Backup $name) -Destination $metadata }
   }
   Restore-AmpsEndpointNames -Path (Join-Path $Backup 'endpoints.json')
   foreach ($name in @('AMPS', 'AudioArray')) {
      $xmlPath = Join-Path $Backup "$name.task.xml"
      if (Test-Path -LiteralPath $xmlPath) {
         Register-ScheduledTask -TaskName $name -Xml (Get-Content -LiteralPath $xmlPath -Raw) -Force | Out-Null
      } elseif (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
         Unregister-ScheduledTask -TaskName $name -Confirm:$false
      }
      $shortcut = Join-Path $shortcutRoot "$name.lnk"
      if (Test-Path -LiteralPath $shortcut) { Move-Item -LiteralPath $shortcut -Destination (Join-Path $Backup "failed-$name.lnk") }
      if (Test-Path -LiteralPath (Join-Path $Backup "$name.lnk")) { Copy-Item -LiteralPath (Join-Path $Backup "$name.lnk") -Destination $shortcut }
   }
   foreach ($task in $state.Tasks) { if ($task.Resume) { Start-ScheduledTask -TaskName $task.Name } }
   Write-Warning "Restored the previous installation and endpoint names. Recovery files: $Backup"
}

function Complete-AmpsDeployment {
   param([string]$Backup)
   $before = Get-Content -LiteralPath (Join-Path $Backup 'endpoints.json') -Raw | ConvertFrom-Json
   $after = @(Get-VacEndpoints)
   if ($before.Count -gt 0 -and (
      $after.Count -ne $before.Count -or
      (Compare-Object ($before.ItemId | Sort-Object) ($after.ItemId | Sort-Object))
   )) { throw 'Endpoint identities changed; refusing to retire the previous startup registration.' }
   if (Get-ScheduledTask -TaskName AudioArray -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName AudioArray -Confirm:$false
   }
   $shortcut = Join-Path $shortcutRoot 'AudioArray.lnk'
   if (Test-Path -LiteralPath $shortcut) {
      Move-Item -LiteralPath $shortcut -Destination (Join-Path $Backup 'retired-AudioArray.lnk')
   }
   'Verified AMPS cutover; legacy files retained for recovery.' | Set-Content -LiteralPath (Join-Path $Backup 'complete.txt')
}

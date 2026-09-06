# Packaged terminal hosts can redirect AppData writes into their private store.
# Reconciliation must see the same directories as the ordinary logon task.
function Test-AmpsPackagedHost {
   if (-not ('AMPS.PackageContext' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AMPS {
   public static class PackageContext {
      [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
      public static extern int GetCurrentPackageFullName(ref uint length, System.Text.StringBuilder name);
   }
}
'@
   }
   [uint32]$length = 0
   $result = [AMPS.PackageContext]::GetCurrentPackageFullName([ref]$length, $null)
   if ($result -eq 15700) { return $false } # APPMODEL_ERROR_NO_PACKAGE
   if ($result -eq 122 -or $result -eq 0) { return $true }
   throw "Unable to determine the installer application context: $result"
}

function Invoke-AmpsUnpackaged {
   param([string]$ScriptPath, [System.Collections.IDictionary]$Parameters)
   $id = [guid]::NewGuid().ToString('N')
   $task = "Dotfiles AMPS reconciliation $id"
   # USERPROFILE is not subject to packaged AppData redirection.
   $work = Join-Path $env:USERPROFILE ".cache\dotfiles-amps\$id"
   New-Item -ItemType Directory -Path $work -Force | Out-Null
   $request = Join-Path $work 'request.xml'
   $log = Join-Path $work 'reconcile.log'
   $plainParameters = @{}
   foreach ($key in $Parameters.Keys) {
      $value = $Parameters[$key]
      if ($value -is [System.Management.Automation.SwitchParameter]) { $value = [bool]$value }
      $plainParameters[$key] = $value
   }
   @{ ScriptPath = $ScriptPath; Parameters = $plainParameters } | Export-Clixml -LiteralPath $request
   $command = @'
$ErrorActionPreference = 'Stop'
$request = Import-Clixml -LiteralPath '__REQUEST__'
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC'
Start-Transcript -LiteralPath '__LOG__' | Out-Null
try {
   $arguments = $request.Parameters
   & $request.ScriptPath @arguments
   exit $LASTEXITCODE
} catch {
   Write-Error $_ -ErrorAction Continue
   exit 1
} finally { Stop-Transcript | Out-Null }
'@
   $command = $command.Replace('__REQUEST__', $request.Replace("'", "''")).Replace('__LOG__', $log.Replace("'", "''"))
   $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
   $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encoded"
   $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
   $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
   Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings | Out-Null
   try {
      Write-Host "Reconciling AMPS in the normal Windows user context, without elevation. Log: $log"
      Start-ScheduledTask -TaskName $task
      $deadline = (Get-Date).AddHours(2)
      do {
         Start-Sleep -Seconds 2
         $info = Get-ScheduledTaskInfo -TaskName $task
         $state = Get-ScheduledTask -TaskName $task
         $finished = $info.LastRunTime.Year -gt 2000 -and $state.State -ne 'Running' -and $state.State -ne 'Queued'
      } until ($finished -or (Get-Date) -ge $deadline)
      if (-not $finished) { throw "AMPS reconciliation is still running. Inspect $task and $log before retrying." }
      if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Write-Host }
      if ($info.LastTaskResult -ne 0) { throw "AMPS reconciliation failed with exit code $($info.LastTaskResult). Log: $log" }
   } finally {
      # Never interrupt an active deployment if the waiting caller goes away.
      if ((Get-ScheduledTask -TaskName $task).State -notin @('Running', 'Queued')) {
         Unregister-ScheduledTask -TaskName $task -Confirm:$false
      }
   }
}

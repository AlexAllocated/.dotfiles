param(
   [ValidateSet("Ensure", "Install", "Refresh", "Remove")]
   [string]$Mode = "Ensure",
   [string]$DistroName = "Ubuntu-26.04",
   [int]$WindowsPort = 22,
   [int]$LinuxPort = 22
)

$ErrorActionPreference = "Stop"
$TaskName = "Dotfiles WSL SSH Forward"
$FirewallRuleName = "Dotfiles-WSL-SSH"
$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$Wsl = "$env:SystemRoot\System32\wsl.exe"

function Test-Administrator {
   $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
   $principal = [Security.Principal.WindowsPrincipal]::new($identity)
   return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedInstall {
   $arguments = @(
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", ('"{0}"' -f $PSCommandPath),
      "-Mode", "Install",
      "-DistroName", $DistroName,
      "-WindowsPort", [string]$WindowsPort,
      "-LinuxPort", [string]$LinuxPort
   )
   $process = Start-Process -FilePath $PowerShell -Verb RunAs -Wait -PassThru -ArgumentList $arguments
   if ($process.ExitCode -ne 0) {
      throw "Elevated SSH-forward installation exited with status $($process.ExitCode)."
   }
}

function Get-ForwardTaskActionArguments {
   return @(
      "-NoLogo",
      "-NoProfile",
      "-WindowStyle", "Hidden",
      "-ExecutionPolicy", "Bypass",
      "-File", ('"{0}"' -f $PSCommandPath),
      "-Mode", "Refresh",
      "-DistroName", $DistroName,
      "-WindowsPort", [string]$WindowsPort,
      "-LinuxPort", [string]$LinuxPort
   ) -join " "
}

function Test-ForwardTaskCurrent {
   param([Parameter(Mandatory = $true)][string]$ActionArguments)

   $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
   return [bool](
      $task -and
      $task.Actions.Count -eq 1 -and
      $task.Actions[0].Execute -ieq $PowerShell -and
      $task.Actions[0].Arguments -eq $ActionArguments -and
      $task.Principal.RunLevel.ToString() -eq "Highest" -and
      $task.Triggers.Count -eq 1 -and
      $task.Triggers[0].CimClass.CimClassName -eq "MSFT_TaskLogonTrigger" -and
      $task.Settings.ExecutionTimeLimit -eq "PT5M" -and
      $task.Settings.MultipleInstances.ToString() -eq "IgnoreNew" -and
      $task.Settings.StartWhenAvailable -eq $true
   )
}

function Get-WslAddress {
   & $Wsl --distribution $DistroName --user root --exec `
      /bin/sh -lc "systemctl is-active --quiet ssh.service || systemctl is-active --quiet sshd.service"
   if ($LASTEXITCODE -ne 0) {
      & $Wsl --distribution $DistroName --user root --exec `
         /bin/sh -lc "systemctl start ssh.service || systemctl start sshd.service"
      if ($LASTEXITCODE -ne 0) {
         throw "Could not start the SSH service inside the $DistroName distro."
      }
   }

   $addressOutput = & $Wsl --distribution $DistroName --user root --exec `
      /bin/sh -lc "ip -4 -o address show dev eth0 scope global"
   if ($LASTEXITCODE -ne 0) {
      throw "Could not read the $DistroName eth0 address."
   }
   $addressMatch = [regex]::Match(($addressOutput -join "`n"), '\binet\s+(\d+\.\d+\.\d+\.\d+)/')
   if (-not $addressMatch.Success) {
      throw "The $DistroName distro has no global IPv4 address on eth0."
   }
   return $addressMatch.Groups[1].Value
}

function Get-ExistingForwardAddress {
   $output = (& netsh interface portproxy show v4tov4) -join "`n"
   $pattern = '(?m)^\s*0\.0\.0\.0\s+' + $WindowsPort + '\s+(\d+\.\d+\.\d+\.\d+)\s+' + $LinuxPort + '\s*$'
   $match = [regex]::Match($output, $pattern)
   if ($match.Success) {
      return $match.Groups[1].Value
   }
   return $null
}

function Set-FirewallRule {
   $rule = Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue
   if (-not $rule) {
      $rule = New-NetFirewallRule `
         -Name $FirewallRuleName `
         -DisplayName "WSL SSH from the private LAN" `
         -Description "Allow Windows port $WindowsPort to reach the key-only SSH server in $DistroName." `
         -Enabled True `
         -Profile Private `
         -Direction Inbound `
         -Action Allow `
         -Protocol TCP `
         -LocalPort $WindowsPort `
         -RemoteAddress LocalSubnet
   } else {
      $rule | Set-NetFirewallRule -Enabled True -Profile Private -Direction Inbound -Action Allow | Out-Null
      $rule | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP -LocalPort $WindowsPort | Out-Null
      $rule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress LocalSubnet | Out-Null
   }
}

function Update-Forward {
   if (-not (Test-Administrator)) {
      throw "Refreshing the Windows SSH forward requires elevation."
   }

   $windowsSsh = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
   if ($windowsSsh -and $windowsSsh.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
      throw "Windows OpenSSH already owns port $WindowsPort; refusing to replace it with a WSL forward."
   }

   Set-Service -Name "iphlpsvc" -StartupType Automatic
   $ipHelper = Get-Service -Name "iphlpsvc"
   if ($ipHelper.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
      Start-Service -Name "iphlpsvc"
   }

   $wslAddress = Get-WslAddress
   $existingAddress = Get-ExistingForwardAddress
   if ($existingAddress -ne $wslAddress) {
      if ($existingAddress) {
         & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$WindowsPort | Out-Null
      }
      & netsh interface portproxy add v4tov4 `
         listenaddress=0.0.0.0 listenport=$WindowsPort `
         connectaddress=$wslAddress connectport=$LinuxPort | Out-Null
      if ($LASTEXITCODE -ne 0) {
         throw "Could not create the Windows-to-WSL SSH port forward."
      }
   }

   Set-FirewallRule
   Write-Host "Windows 0.0.0.0:$WindowsPort forwards to $DistroName at ${wslAddress}:$LinuxPort."
   Write-Host "The firewall permits TCP $WindowsPort only from the Private-profile local subnet."
}

function Install-Forward {
   if (-not (Test-Administrator)) {
      throw "Installing the Windows SSH-forward task requires elevation."
   }

   $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
   $actionArguments = Get-ForwardTaskActionArguments
   $action = New-ScheduledTaskAction -Execute $PowerShell -Argument $actionArguments
   $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
   $principal = New-ScheduledTaskPrincipal `
      -UserId $identity -LogonType Interactive -RunLevel Highest
   $settings = New-ScheduledTaskSettingsSet `
      -AllowStartIfOnBatteries `
      -DontStopIfGoingOnBatteries `
      -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5)) `
      -MultipleInstances IgnoreNew `
      -StartWhenAvailable

   Register-ScheduledTask `
      -TaskName $TaskName `
      -Description "Keep Windows port $WindowsPort forwarded to the key-only $DistroName SSH server." `
      -Action $action `
      -Trigger $trigger `
      -Principal $principal `
      -Settings $settings `
      -Force | Out-Null
   Update-Forward
   Write-Host "Installed the event-driven '$TaskName' logon task."
}

function Remove-Forward {
   if (-not (Test-Administrator)) {
      throw "Removing the Windows SSH forward requires elevation."
   }
   Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
   Remove-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue
   & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$WindowsPort | Out-Null
   Write-Host "Removed the $DistroName SSH forward, firewall rule, and scheduled task."
}

switch ($Mode) {
   "Ensure" {
      $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
      $actionArguments = Get-ForwardTaskActionArguments
      if (-not $task -or -not (Test-ForwardTaskCurrent -ActionArguments $actionArguments)) {
         Invoke-ElevatedInstall
      } else {
         $wslAddress = Get-WslAddress
         if ((Get-ExistingForwardAddress) -eq $wslAddress) {
            Write-Host "Windows 0.0.0.0:$WindowsPort already forwards to $DistroName at ${wslAddress}:$LinuxPort."
         } else {
            Start-ScheduledTask -TaskName $TaskName
            Write-Host "Requested an asynchronous SSH-forward repair from '$TaskName'."
         }
      }
   }
   "Install" { Install-Forward }
   "Refresh" { Update-Forward }
   "Remove" { Remove-Forward }
}

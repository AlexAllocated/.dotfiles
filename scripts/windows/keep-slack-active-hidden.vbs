Option Explicit

Dim command
Dim exitCode
Dim fileSystem
Dim intervalSeconds
Dim powerShell
Dim scriptDirectory
Dim scriptPath
Dim shell

Set fileSystem = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fileSystem.BuildPath(scriptDirectory, "keep-slack-active.ps1")
powerShell = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
intervalSeconds = "300"
If WScript.Arguments.Count > 0 Then
	intervalSeconds = WScript.Arguments(0)
End If

command = Chr(34) & powerShell & Chr(34) & _
	" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass" & _
	" -File " & Chr(34) & scriptPath & Chr(34) & _
	" -Mode Run -IntervalSeconds " & intervalSeconds

' Wait for the long-running PowerShell worker so Task Scheduler can monitor it,
' while window style 0 prevents Windows Terminal from creating a visible tab.
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

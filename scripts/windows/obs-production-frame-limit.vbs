Option Explicit

Dim arguments, fileSystem, frameLimiter, mode, scriptDirectory, shell
Set arguments = WScript.Arguments

If arguments.Count <> 1 Then
	WScript.Quit 2
End If

mode = arguments.Item(0)
If mode <> "Production" And mode <> "RestoreProduction" Then
	WScript.Quit 2
End If

Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
frameLimiter = fileSystem.BuildPath(scriptDirectory, "set-nvidia-frame-limit.ps1")
If Not fileSystem.FileExists(frameLimiter) Then
	WScript.Quit 3
End If

Set shell = CreateObject("WScript.Shell")
WScript.Quit shell.Run( _
	"powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & _
	frameLimiter & """ -Mode " & mode, _
	0, _
	True _
)

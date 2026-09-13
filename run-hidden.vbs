' Starts Watch-Pdf.ps1 without any visible window.
' (Task Scheduler launching powershell.exe directly flashes a console window at every run.)
Set fso = CreateObject("Scripting.FileSystemObject")
script = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "Watch-Pdf.ps1")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & script & """"
' 0 = hidden window, True = wait, so Task Scheduler gets the script's exit code.
WScript.Quit CreateObject("WScript.Shell").Run(cmd, 0, True)

using System;
using System.Diagnostics;
using System.IO;

public static class NvimWSL
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length == 0 || string.IsNullOrWhiteSpace(args[0]))
        {
            return 2;
        }

        string systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string powershell = Path.Combine(
            systemRoot,
            @"System32\WindowsPowerShell\v1.0\powershell.exe"
        );
        string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "open-in-nvim.ps1");

        var startInfo = new ProcessStartInfo
        {
            FileName = powershell,
            Arguments = string.Join(" ", new[]
            {
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                Quote(script),
                Quote(args[0])
            }),
            CreateNoWindow = true,
            UseShellExecute = false
        };

        using (Process process = Process.Start(startInfo))
        {
            if (process == null)
            {
                return 1;
            }

            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}

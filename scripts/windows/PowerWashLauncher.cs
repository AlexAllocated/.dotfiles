using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

public static class PowerWashLauncher
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
		string localAppData = Environment.GetFolderPath(
			Environment.SpecialFolder.LocalApplicationData
		);
		string script = Path.Combine(
			localAppData,
			@"dotfiles\configure-powerwash-simulator-2.ps1"
		);
		string logDirectory = Path.Combine(localAppData, @"dotfiles\logs");
		string logPath = Path.Combine(logDirectory, "powerwash-launcher.log");
		Directory.CreateDirectory(logDirectory);

		var powershellArguments = new List<string>
		{
			"-NoLogo",
			"-NoProfile",
			"-NonInteractive",
			"-ExecutionPolicy",
			"Bypass",
			"-WindowStyle",
			"Hidden",
			"-File",
			script,
			"-Mode",
			"Launch"
		};
		powershellArguments.AddRange(args);

		var startInfo = new ProcessStartInfo
		{
			FileName = powershell,
			Arguments = JoinArguments(powershellArguments),
			CreateNoWindow = true,
			RedirectStandardError = true,
			RedirectStandardOutput = true,
			UseShellExecute = false,
			WindowStyle = ProcessWindowStyle.Hidden
		};

		using (Process process = Process.Start(startInfo))
		{
			if (process == null)
			{
				return 1;
			}

			string standardOutput = process.StandardOutput.ReadToEnd();
			string standardError = process.StandardError.ReadToEnd();
			process.WaitForExit();
			if (process.ExitCode != 0 || standardError.Length > 0)
			{
				File.AppendAllText(
					logPath,
					string.Format(
						"[{0:O}] exit={1}{2}{3}{2}{4}{2}",
						DateTimeOffset.Now,
						process.ExitCode,
						Environment.NewLine,
						standardOutput,
						standardError
					),
					Encoding.UTF8
				);
			}
			return process.ExitCode;
		}
	}

	private static string JoinArguments(IEnumerable<string> arguments)
	{
		var commandLine = new StringBuilder();
		foreach (string argument in arguments)
		{
			if (commandLine.Length > 0)
			{
				commandLine.Append(' ');
			}
			commandLine.Append(QuoteArgument(argument ?? string.Empty));
		}
		return commandLine.ToString();
	}

	private static string QuoteArgument(string argument)
	{
		if (argument.Length > 0 && argument.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
		{
			return argument;
		}

		var quoted = new StringBuilder("\"");
		int backslashes = 0;
		foreach (char character in argument)
		{
			if (character == '\\')
			{
				backslashes++;
				continue;
			}

			if (character == '"')
			{
				quoted.Append('\\', backslashes * 2 + 1);
				quoted.Append(character);
				backslashes = 0;
				continue;
			}

			quoted.Append('\\', backslashes);
			backslashes = 0;
			quoted.Append(character);
		}
		quoted.Append('\\', backslashes * 2);
		quoted.Append('"');
		return quoted.ToString();
	}
}

using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace CodexDesktopProxyLauncher
{
    // Tiny WinForms bootstrapper. The real launcher stays in PowerShell so
    // users can inspect and repair it without a full .NET project.
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            // The packaged EXE must live next to the PowerShell script. This
            // keeps the ZIP portable after extraction.
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(baseDir, "codex-only-proxy-launcher.ps1");

            if (!File.Exists(scriptPath))
            {
                MessageBox.Show(
                    "codex-only-proxy-launcher.ps1 was not found next to this executable.",
                    "Codex Proxy Launcher",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }

            string powershellPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");

            if (!File.Exists(powershellPath))
            {
                powershellPath = "powershell.exe";
            }

            // Forward startup flags such as -AutoStartProxy and -StartMinimized
            // to the PowerShell launcher.
            string passThroughArgs = string.Join(" ", args.Select(QuoteArgument));
            string arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "
                + QuoteArgument(scriptPath);

            if (!string.IsNullOrWhiteSpace(passThroughArgs))
            {
                arguments += " " + passThroughArgs;
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = powershellPath,
                Arguments = arguments,
                WorkingDirectory = baseDir,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            Process.Start(startInfo);
            return 0;
        }

        private static string QuoteArgument(string value)
        {
            // Escape for a Windows command line passed through ProcessStartInfo.
            if (string.IsNullOrEmpty(value))
            {
                return "\"\"";
            }

            return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }
    }
}

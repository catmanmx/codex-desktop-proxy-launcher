using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace CodexDesktopProxyLauncher
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
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
            if (string.IsNullOrEmpty(value))
            {
                return "\"\"";
            }

            return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }
    }
}

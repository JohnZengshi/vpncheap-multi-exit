using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

[assembly: AssemblyTitle("VPNCheap Multi Exit")]
[assembly: AssemblyDescription("Portable launcher for the VPNCheap multi-exit broker.")]
[assembly: AssemblyProduct("VPNCheap Multi Exit")]
[assembly: AssemblyCompany("VPNCheap Multi Exit")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

internal static class Program
{
    private const string ManifestResourceName = "bundle.manifest";
    private const string BundleRootName = "VPNCheapMultiExit";

    private static int Main(string[] args)
    {
        try
        {
            Console.OutputEncoding = new UTF8Encoding(false);
            string home = ResolveHome();

            if (args.Length == 0 || IsHelp(args[0]))
            {
                PrintUsage();
                return 0;
            }

            return Dispatch(args, home);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("vpncheap: " + ex.Message);
            return 1;
        }
    }

    private static int Dispatch(string[] args, string home)
    {
        string command = args[0].Trim().ToLowerInvariant();
        switch (command)
        {
            case "help":
            case "--help":
            case "-h":
            case "/?":
                PrintUsage();
                return 0;
            case "version":
            case "--version":
                Console.WriteLine(Assembly.GetExecutingAssembly().GetName().Version);
                return 0;
            case "path":
                Console.WriteLine("home=" + home);
                Console.WriteLine("runtime=" + Path.Combine(home, "runtime"));
                return 0;
            case "scripts":
                PrintScripts(home);
                return 0;
            case "restart":
                return RunPowerShell(home, "scripts\\install-broker-task.ps1", Prepend("-StartNow", Tail(args, 1)));
            case "start":
                return RunPowerShell(home, "scripts\\broker.ps1", Prepend("-Action", "start", Tail(args, 1)));
            case "stop":
                return RunPowerShell(home, "scripts\\broker.ps1", Prepend("-Action", "stop", Tail(args, 1)));
            case "status":
                return RunPowerShell(home, "scripts\\broker.ps1", Prepend("-Action", "status", Tail(args, 1)));
            case "dashboard":
                return RunDashboard(home, Tail(args, 1));
            case "task":
                return RunTask(home, Tail(args, 1));
            case "9router":
                return RunNineRouter(home, Tail(args, 1));
            case "inspect":
                return RunPowerShell(home, "scripts\\inspect-managed-surface.ps1", Tail(args, 1));
            case "recover":
                return RunPowerShell(home, "scripts\\recover-vpncheap-state.ps1", Tail(args, 1));
            case "probe":
                return RunPowerShell(home, "scripts\\multiexit-probe.ps1", Tail(args, 1));
            case "run":
                return RunUserScript(home, Tail(args, 1));
            default:
                Console.Error.WriteLine("vpncheap: unknown command '" + args[0] + "'");
                PrintUsage();
                return 2;
        }
    }

    private static int RunDashboard(string home, string[] args)
    {
        if (args.Length == 0)
        {
            return RunPowerShell(home, "scripts\\dashboard.ps1", new string[0]);
        }

        string action = args[0].Trim().ToLowerInvariant();
        if (action == "start" || action == "stop" || action == "status" || action == "run")
        {
            return RunPowerShell(home, "scripts\\dashboard.ps1", Prepend("-Action", action, Tail(args, 1)));
        }

        if (args[0].StartsWith("-", StringComparison.Ordinal))
        {
            return RunPowerShell(home, "scripts\\dashboard.ps1", Prepend("-Action", "start", args));
        }

        throw new ArgumentException("dashboard expects start, stop, status, or run.");
    }

    private static int RunTask(string home, string[] args)
    {
        if (args.Length == 0)
        {
            throw new ArgumentException("task expects install, restart, or remove.");
        }

        string action = args[0].Trim().ToLowerInvariant();
        string[] rest = Tail(args, 1);
        switch (action)
        {
            case "install":
                return RunPowerShell(home, "scripts\\install-broker-task.ps1", rest);
            case "restart":
            case "start":
                return RunPowerShell(home, "scripts\\install-broker-task.ps1", Prepend("-StartNow", rest));
            case "remove":
            case "uninstall":
                return RunPowerShell(home, "scripts\\install-broker-task.ps1", Prepend("-Uninstall", rest));
            default:
                throw new ArgumentException("task expects install, restart, or remove.");
        }
    }

    private static int RunNineRouter(string home, string[] args)
    {
        if (args.Length == 0)
        {
            throw new ArgumentException("9router expects inventory, plan, apply, or rollback.");
        }

        string action = args[0].Trim().ToLowerInvariant();
        string[] rest = Tail(args, 1);
        string script;
        switch (action)
        {
            case "inventory":
                script = "scripts\\9router-inventory.ps1";
                break;
            case "plan":
                script = "scripts\\9router-plan.ps1";
                break;
            case "apply":
                script = "scripts\\9router-apply.ps1";
                break;
            case "rollback":
                script = "scripts\\9router-rollback.ps1";
                break;
            default:
                throw new ArgumentException("9router expects inventory, plan, apply, or rollback.");
        }

        return RunPowerShell(home, script, rest);
    }

    private static int RunUserScript(string home, string[] args)
    {
        if (args.Length == 0)
        {
            throw new ArgumentException("run expects a script name, for example: run broker.ps1 -Action status");
        }

        string name = args[0].Trim().Replace('/', '\\');
        if (Path.IsPathRooted(name))
        {
            throw new ArgumentException("run expects a script name relative to the scripts directory.");
        }
        if (name.StartsWith("scripts\\", StringComparison.OrdinalIgnoreCase))
        {
            name = name.Substring("scripts\\".Length);
        }
        if (!name.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase))
        {
            name += ".ps1";
        }

        string scriptsDirectory = Path.GetFullPath(Path.Combine(home, "scripts"));
        string scriptPath = Path.GetFullPath(Path.Combine(scriptsDirectory, name));
        if (!IsUnderRoot(scriptPath, scriptsDirectory))
        {
            throw new ArgumentException("run script must stay inside the scripts directory.");
        }

        return RunPowerShellPath(home, scriptPath, Tail(args, 1));
    }

    private static void PrintScripts(string home)
    {
        string scriptsDirectory = Path.Combine(home, "scripts");
        string[] files = Directory.GetFiles(scriptsDirectory, "*.ps1", SearchOption.AllDirectories);
        Array.Sort(files, StringComparer.OrdinalIgnoreCase);
        foreach (string file in files)
        {
            string relative = file.Substring(scriptsDirectory.Length).TrimStart('\\', '/');
            Console.WriteLine(relative.Replace('\\', '/'));
        }
    }

    private static void PrintUsage()
    {
        Console.WriteLine("VPNCheap Multi Exit launcher");
        Console.WriteLine();
        Console.WriteLine("Usage:");
        Console.WriteLine("  vpncheap.exe restart                          restart the scheduled broker");
        Console.WriteLine("  vpncheap.exe start | stop | status            control the broker directly");
        Console.WriteLine("  vpncheap.exe dashboard [start|stop|status]    control the dashboard");
        Console.WriteLine("  vpncheap.exe task [install|restart|remove]    manage the scheduled task");
        Console.WriteLine("  vpncheap.exe 9router <inventory|plan|apply|rollback> [args]");
        Console.WriteLine("  vpncheap.exe inspect | recover | probe [args]");
        Console.WriteLine("  vpncheap.exe run <script.ps1> [args]          pass args to any script");
        Console.WriteLine("  vpncheap.exe scripts | path | version");
        Console.WriteLine();
        Console.WriteLine("Examples:");
        Console.WriteLine("  vpncheap.exe run broker.ps1 -Action status");
        Console.WriteLine("  vpncheap.exe run 9router-plan.ps1 -AllowRebind");
        Console.WriteLine("  vpncheap.exe dashboard start -Port 39081");
    }

    private static string ResolveHome()
    {
        string configured = Environment.GetEnvironmentVariable("VPNCHEAP_HOME");
        if (!String.IsNullOrWhiteSpace(configured))
        {
            return PrepareConfiguredHome(Path.GetFullPath(configured));
        }

        string executableDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\', '/');
        DirectoryInfo parent = Directory.GetParent(executableDirectory);
        string[] candidates = new string[]
        {
            executableDirectory,
            parent == null ? null : parent.FullName
        };

        foreach (string candidate in candidates)
        {
            if (candidate == null)
            {
                continue;
            }
            if (File.Exists(Path.Combine(candidate, "scripts", "broker.ps1")))
            {
                return Path.GetFullPath(candidate);
            }
        }

        string localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (String.IsNullOrWhiteSpace(localApplicationData))
        {
            throw new InvalidOperationException("LOCALAPPDATA is not available. Set VPNCHEAP_HOME.");
        }

        return PrepareStandaloneHome(Path.Combine(localApplicationData, BundleRootName));
    }

    private static string PrepareConfiguredHome(string home)
    {
        Directory.CreateDirectory(home);
        if (!File.Exists(Path.Combine(home, "scripts", "broker.ps1")))
        {
            ExtractBundle(home);
        }
        return home;
    }

    private static string PrepareStandaloneHome(string home)
    {
        Directory.CreateDirectory(home);
        ExtractBundle(home);
        return home;
    }

    private static void ExtractBundle(string home)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        string manifest;
        using (Stream stream = assembly.GetManifestResourceStream(ManifestResourceName))
        {
            if (stream == null)
            {
                throw new InvalidOperationException("embedded bundle manifest is missing");
            }
            using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true))
            {
                manifest = reader.ReadToEnd();
            }
        }

        int extracted = 0;
        string[] lines = manifest.Split(new string[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
        foreach (string line in lines)
        {
            int separator = line.IndexOf('|');
            if (separator <= 0 || separator == line.Length - 1)
            {
                continue;
            }

            string resourceName = line.Substring(0, separator).Trim();
            string relativePath = line.Substring(separator + 1).Trim().Replace('/', '\\');
            string targetPath = Path.GetFullPath(Path.Combine(home, relativePath));
            if (!IsUnderRoot(targetPath, home))
            {
                throw new InvalidOperationException("embedded bundle contains an unsafe path");
            }

            using (Stream stream = assembly.GetManifestResourceStream(resourceName))
            {
                if (stream == null)
                {
                    throw new InvalidOperationException("embedded resource is missing: " + resourceName);
                }
                using (MemoryStream memory = new MemoryStream())
                {
                    stream.CopyTo(memory);
                    byte[] content = memory.ToArray();
                    if (!FileContentsEqual(targetPath, content))
                    {
                        string directory = Path.GetDirectoryName(targetPath);
                        Directory.CreateDirectory(directory);
                        File.WriteAllBytes(targetPath, content);
                        extracted++;
                    }
                }
            }
        }

        if (extracted > 0)
        {
            Console.Error.WriteLine("vpncheap: extracted {0} embedded file(s) to {1}", extracted, home);
        }
    }

    private static bool FileContentsEqual(string path, byte[] content)
    {
        if (!File.Exists(path))
        {
            return false;
        }
        if (new FileInfo(path).Length != content.Length)
        {
            return false;
        }

        using (SHA256 sha = SHA256.Create())
        {
            byte[] existing = File.ReadAllBytes(path);
            byte[] expectedHash = sha.ComputeHash(content);
            byte[] existingHash = sha.ComputeHash(existing);
            if (expectedHash.Length != existingHash.Length)
            {
                return false;
            }
            for (int i = 0; i < expectedHash.Length; i++)
            {
                if (expectedHash[i] != existingHash[i])
                {
                    return false;
                }
            }
        }
        return true;
    }

    private static int RunPowerShell(string home, string relativeScriptPath, string[] arguments)
    {
        string scriptPath = Path.GetFullPath(Path.Combine(home, relativeScriptPath));
        return RunPowerShellPath(home, scriptPath, arguments);
    }

    private static int RunPowerShellPath(string home, string scriptPath, string[] arguments)
    {
        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException("script not found: " + scriptPath);
        }

        string powershell = FindPowerShell();
        StringBuilder commandLine = new StringBuilder();
        commandLine.Append("-NoProfile -File ");
        commandLine.Append(QuoteArgument(scriptPath));
        foreach (string argument in arguments)
        {
            commandLine.Append(' ');
            commandLine.Append(QuoteArgument(argument));
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = powershell;
        startInfo.Arguments = commandLine.ToString();
        startInfo.WorkingDirectory = home;
        startInfo.UseShellExecute = false;

        using (Process process = Process.Start(startInfo))
        {
            if (process == null)
            {
                throw new InvalidOperationException("failed to start PowerShell");
            }
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static string FindPowerShell()
    {
        string configured = Environment.GetEnvironmentVariable("VPNCHEAP_PWSH");
        if (!String.IsNullOrWhiteSpace(configured))
        {
            if (File.Exists(configured))
            {
                return configured;
            }
            throw new FileNotFoundException("VPNCHEAP_PWSH does not exist: " + configured);
        }

        string path = Environment.GetEnvironmentVariable("PATH");
        if (!String.IsNullOrWhiteSpace(path))
        {
            foreach (string directory in path.Split(Path.PathSeparator))
            {
                if (String.IsNullOrWhiteSpace(directory))
                {
                    continue;
                }
                string candidate = Path.Combine(directory.Trim().Trim('"'), "pwsh.exe");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
        }

        string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string installed = Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe");
        if (File.Exists(installed))
        {
            return installed;
        }

        throw new FileNotFoundException(
            "PowerShell 7 (pwsh.exe) was not found. Install PowerShell 7 or set VPNCHEAP_PWSH.");
    }

    private static bool IsUnderRoot(string path, string root)
    {
        string normalizedRoot = Path.GetFullPath(root).TrimEnd('\\', '/') + Path.DirectorySeparatorChar;
        string normalizedPath = Path.GetFullPath(path);
        return normalizedPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsHelp(string value)
    {
        string command = value.Trim().ToLowerInvariant();
        return command == "help" || command == "--help" || command == "-h" || command == "/?";
    }

    private static string[] Tail(string[] values, int start)
    {
        if (start >= values.Length)
        {
            return new string[0];
        }
        string[] result = new string[values.Length - start];
        Array.Copy(values, start, result, 0, result.Length);
        return result;
    }

    private static string[] Prepend(string first, string[] values)
    {
        return Prepend(first, null, values);
    }

    private static string[] Prepend(string first, string second, string[] values)
    {
        int prefixLength = second == null ? 1 : 2;
        string[] result = new string[prefixLength + values.Length];
        result[0] = first;
        if (second != null)
        {
            result[1] = second;
        }
        Array.Copy(values, 0, result, prefixLength, values.Length);
        return result;
    }

    private static string QuoteArgument(string value)
    {
        if (value == null)
        {
            value = String.Empty;
        }
        if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            return value;
        }

        StringBuilder result = new StringBuilder();
        result.Append('"');
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                result.Append('\\', (backslashes * 2) + 1);
                result.Append('"');
                backslashes = 0;
                continue;
            }
            result.Append('\\', backslashes);
            result.Append(character);
            backslashes = 0;
        }
        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }
}

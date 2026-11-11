param(
    [Parameter(Mandatory = $true)][string]$LauncherPath,
    [switch]$Live
)
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($LauncherPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$needed = @('Get-ProxyUrl', 'Get-ProxyEnvironment', 'Set-ProxyEnvironment', 'Find-CodexDesktopExe', 'Get-CodexProcesses')
foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($definition.Name -in $needed) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
$script:ProxyHost = '127.0.0.1'
$script:NoProxy = 'localhost,127.0.0.1,::1'
$failures = [System.Collections.Generic.List[string]]::new()
function Check([string]$Name, [bool]$Pass) {
    if ($Pass) { Write-Output "PASS: $Name" }
    else { Write-Output "FAIL: $Name"; $failures.Add($Name) }
}

# These functions build the actual environment handed to a child process.
$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
Set-ProxyEnvironment -StartInfo $startInfo -Port 10808
Check 'WebSocket child process opts into the environment proxy' ($startInfo.EnvironmentVariables['NODE_USE_ENV_PROXY'] -eq '1')
Check 'HTTPS child process uses the selected local proxy' ($startInfo.EnvironmentVariables['HTTPS_PROXY'] -eq 'http://127.0.0.1:10808')
Check 'Loopback traffic remains local' ($startInfo.EnvironmentVariables['NO_PROXY'] -eq 'localhost,127.0.0.1,::1')

if ($Live) {
    $desktopExe = Find-CodexDesktopExe
    Check 'Installed ChatGPT desktop executable is located' ($desktopExe -match '\\OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$' -and (Test-Path -LiteralPath $desktopExe))
    $currentDesktop = @(Microsoft.PowerShell.Management\Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
    $selected = @(Get-CodexProcesses)
    Check 'Current ChatGPT desktop processes are detected' ($currentDesktop.Count -gt 0 -and @($currentDesktop | Where-Object { $_.Id -notin $selected.Id }).Count -eq 0)
    Check 'CLI executables are excluded from desktop restart targets' (@($selected | Where-Object { $_.Path -match '\\(?:resources|bin)\\' }).Count -eq 0)
    Write-Output "Located executable: $desktopExe"
} else {
    # OS enumeration is the boundary; production selection code stays unchanged.
    $script:fixtureRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.1103.4239.0_x64__2p2nqsd0c76g0'
    $script:fixtures = @(
        [pscustomobject]@{ Id=10; ProcessName='ChatGPT'; Path="$script:fixtureRoot\app\ChatGPT.exe"; StartTime=[datetime]'2026-11-09T10:00:00' },
        [pscustomobject]@{ Id=11; ProcessName='codex'; Path='C:\Users\Example\AppData\Local\OpenAI\Codex\bin\runtime\codex.exe'; StartTime=[datetime]'2026-11-09T11:00:00' },
        [pscustomobject]@{ Id=12; ProcessName='codex'; Path="$script:fixtureRoot\app\resources\codex.exe"; StartTime=[datetime]'2026-11-09T12:00:00' },
        [pscustomobject]@{ Id=13; ProcessName='ChatGPT'; Path='D:\Unrelated\ChatGPT.exe'; StartTime=[datetime]'2026-11-09T13:00:00' }
    )
    function Get-Process { param([string]$Name, $ErrorAction) $script:fixtures | Where-Object ProcessName -eq $Name }
    function Test-Path { param([string]$Path, [string]$LiteralPath) (($Path + $LiteralPath) -eq "$script:fixtureRoot\app\ChatGPT.exe") }
    function Get-AppxPackage { param($ErrorAction) [pscustomobject]@{ Name='OpenAI.Codex'; PackageFamilyName='OpenAI.Codex_2p2nqsd0c76g0'; Version=[version]'26.1103.4239.0'; InstallLocation=$script:fixtureRoot } }
    $selectedIds = @((Get-CodexProcesses).Id)
    Check 'Restart targets contain the desktop and exclude CLI and unrelated apps' ($selectedIds.Count -eq 1 -and $selectedIds[0] -eq 10)
    Check 'Running desktop is preferred over a newer CLI process' ((Find-CodexDesktopExe) -eq "$script:fixtureRoot\app\ChatGPT.exe")
    $script:fixtures = @()
    Check 'Package discovery finds ChatGPT.exe when the desktop is closed' ((Find-CodexDesktopExe) -eq "$script:fixtureRoot\app\ChatGPT.exe")
}
if ($failures.Count) { throw "$($failures.Count) regression check(s) failed: $($failures -join '; ')" }
Write-Output 'All launcher repair checks passed.'

param([Parameter(Mandatory=$true)][string]$LauncherPath)
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($LauncherPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($definition in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){
    if($definition.Name -in @('Get-ProxyUrl','Test-CodexProxyModeRunning')){. ([scriptblock]::Create($definition.Extent.Text))}
}
$script:ProxyHost='127.0.0.1'
$script:desktopIds=@(100,101)
$script:rows=@([pscustomobject]@{ProcessId=100;CommandLine='"C:\app\ChatGPT.exe"'})
function Read-Config { [pscustomobject]@{Mode='proxy';Port=10808} }
function Test-AnyCodexRunning { $script:desktopIds.Count -gt 0 }
function Get-CodexProcesses { foreach($idValue in $script:desktopIds){[pscustomobject]@{Id=$idValue}} }
function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) $script:rows }
$failures=[System.Collections.Generic.List[string]]::new()
function Check([string]$Name,[bool]$Ok){if($Ok){"PASS: $Name"}else{"FAIL: $Name";$failures.Add($Name)}}
Check 'Saved proxy mode does not hide an ordinary application restart' (-not (Test-CodexProxyModeRunning -Port 10808))
$script:rows[0].CommandLine='"C:\app\ChatGPT.exe" --proxy-server=http://127.0.0.1:10808 --proxy-bypass-list=localhost;127.0.0.1;::1'
Check 'Matching live main-process proxy is detected' (Test-CodexProxyModeRunning -Port 10808)
Check 'A different requested port is not reported as active' (-not (Test-CodexProxyModeRunning -Port 7890))
$script:rows[0].CommandLine='"C:\app\ChatGPT.exe" --proxy-server=http://127.0.0.1:108080'
Check 'Port prefixes do not count as an exact match' (-not (Test-CodexProxyModeRunning -Port 10808))
$script:rows=@([pscustomobject]@{ProcessId=100;CommandLine='"C:\app\ChatGPT.exe"'},[pscustomobject]@{ProcessId=101;CommandLine='"C:\app\ChatGPT.exe" --type=renderer --proxy-server=http://127.0.0.1:10808'})
Check 'A renderer argument does not certify the main process' (-not (Test-CodexProxyModeRunning -Port 10808))
$script:desktopIds=@()
Check 'Stopped desktop is not reported as proxied' (-not (Test-CodexProxyModeRunning -Port 10808))
if($failures.Count){throw "$($failures.Count) regression checks failed: $($failures -join '; ')"}

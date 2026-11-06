param([string]$PythonCommand='python',[switch]$RegisterCodex,[switch]$RegisterClaude,[switch]$Yes)
$ErrorActionPreference='Stop'
$toolRoot=$PSScriptRoot
$pythonVersion='3.13.9'
# Prompts only when someone can answer; -Yes accepts every offer, redirected input declines them.
function Confirm-Offer([string]$question){if($Yes){return $true};if([Console]::IsInputRedirected){return $false};(Read-Host "$question [Y/n]") -notmatch '^\s*n'}
function Write-Check([string]$name,[bool]$ok,[string]$detail){Write-Host ('  [{0}] {1,-28} {2}' -f $(if($ok){' OK '}else{'MISS'}),$name,$detail) -ForegroundColor $(if($ok){'Green'}else{'Yellow'})}
function Get-PythonInfo([string]$command){
    if(-not (Get-Command $command -ErrorAction SilentlyContinue)){return $null}
    try{$raw=& $command (Join-Path $toolRoot 'bridge.py') info 2>$null}catch{return $null}
    if($LASTEXITCODE -ne 0 -or -not $raw){return $null}
    $info=$raw|ConvertFrom-Json
    if($info.platform -ne 'win32' -or $info.bits -ne 64 -or $info.version[0] -ne 3 -or $info.version[1] -lt 10){return $null}
    $info
}
function Find-Python{
    $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')
    # PATH first, then the per-user and all-user locations used by the python.org installer and Python install manager.
    $candidates=@($PythonCommand,'python')+@(Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe","$env:LOCALAPPDATA\Python\pythoncore-3*-64\python.exe","$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue|Sort-Object FullName -Descending|ForEach-Object FullName)
    foreach($c in $candidates){$info=Get-PythonInfo $c;if($info){return $info}}
    $null
}
function Install-Python{
    if(Get-Command winget -ErrorAction SilentlyContinue){
        & winget install --id Python.Python.3.13 --exact --scope user --silent --accept-source-agreements --accept-package-agreements
        if($LASTEXITCODE -eq 0){return}
        Write-Warning 'winget could not install Python; downloading the installer from python.org instead.'
    }
    $installer=Join-Path ([IO.Path]::GetTempPath()) "python-$pythonVersion-amd64.exe"
    Invoke-WebRequest -UseBasicParsing "https://www.python.org/ftp/python/$pythonVersion/python-$pythonVersion-amd64.exe" -OutFile $installer
    $signature=Get-AuthenticodeSignature -LiteralPath $installer
    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Python Software Foundation'){Remove-Item -LiteralPath $installer;throw 'Downloaded Python installer failed its signature check; not running it.'}
    # Per-user install: no administrator rights, and python is added to the user PATH.
    $process=Start-Process -FilePath $installer -ArgumentList '/quiet','InstallAllUsers=0','PrependPath=1','Include_test=0' -Wait -PassThru
    Remove-Item -LiteralPath $installer -ErrorAction SilentlyContinue
    if($process.ExitCode -ne 0){throw "Python installer exited with code $($process.ExitCode)."}
}

Write-Host 'Checking prerequisites...'
$windowsOk=[Environment]::OSVersion.Platform -eq 'Win32NT' -and [Environment]::Is64BitOperatingSystem
Write-Check 'Windows 64-bit' $windowsOk ([Environment]::OSVersion.VersionString)
if(-not $windowsOk){throw 'Windows UI Bridge needs 64-bit Windows.'}
$windowsPowerShell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
Write-Check 'Windows PowerShell 5.1' (Test-Path -LiteralPath $windowsPowerShell) $windowsPowerShell
if(-not (Test-Path -LiteralPath $windowsPowerShell)){throw 'Windows PowerShell 5.1 is missing; it is part of Windows and cannot be installed by this setup.'}
$netRelease=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
Write-Check '.NET Framework 4.5+' ($netRelease -ge 378389) $(if($netRelease){"release $netRelease"}else{'not found'})
if(-not ($netRelease -ge 378389)){throw '.NET Framework 4.5 or newer is required. Install .NET Framework 4.8 from https://dotnet.microsoft.com/download/dotnet-framework (needs administrator rights).'}
Write-Check 'Interactive desktop session' ([Environment]::UserInteractive) "session $((Get-Process -Id $PID).SessionId)"

$info=Find-Python
Write-Check 'Python 3.10+ (64-bit)' ([bool]$info) $(if($info){"$($info.version -join '.') at $($info.executable)"}else{'not found'})
if(-not $info){
    if(-not (Confirm-Offer "Python 3.10+ (64-bit) was not found. Download and install Python $pythonVersion for this user now?")){throw 'Python is required. Install 64-bit Python 3.10 or newer (https://www.python.org/downloads/windows/ or: winget install Python.Python.3.13), then run setup again.'}
    Install-Python
    $info=Find-Python
    if(-not $info){throw 'Python was installed but could not be found. Open a new window and run setup again.'}
    Write-Check 'Python 3.10+ (64-bit)' $true "$($info.version -join '.') at $($info.executable)"
}

# Setup.cmd bypasses policy for this process only; check what the bridge's own worker process will get.
$policyList=Get-ExecutionPolicy -List
$policy=($policyList|Where-Object{$_.Scope -ne 'Process' -and $_.ExecutionPolicy -ne 'Undefined'}|Select-Object -First 1).ExecutionPolicy
if(-not $policy){$policy=if((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1){'Restricted'}else{'RemoteSigned'}}
$policyOk=$policy -notin 'Restricted','AllSigned'
Write-Check 'Script execution policy' $policyOk "$policy"
if(-not $policyOk){
    $groupPolicy=$policyList|Where-Object{$_.Scope -in 'MachinePolicy','UserPolicy' -and $_.ExecutionPolicy -ne 'Undefined'}
    if($groupPolicy){Write-Warning "Group Policy sets the execution policy to '$policy'; the bridge cannot run worker.ps1. Ask your IT administrator for RemoteSigned."}
    elseif(Confirm-Offer "The bridge runs worker.ps1, which '$policy' blocks. Set your user's execution policy to RemoteSigned?"){Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force;$policy='RemoteSigned'}
    else{Write-Warning "Execution policy '$policy' will block worker.ps1. Later, if your organisation allows it: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"}
}
foreach($client in @(@{flag=$RegisterClaude;name='claude';label='Claude Code CLI'},@{flag=$RegisterCodex;name='codex';label='Codex CLI'})|Where-Object{$_.flag}){
    $found=[bool](Get-Command $client.name -ErrorAction SilentlyContinue)
    Write-Check $client.label $found $(if($found){'found'}else{'not on PATH'})
    if(-not $found){throw "$($client.label) ('$($client.name)') is not on PATH. Install it first, or run setup without its registration flag."}
}

# Files extracted from a downloaded zip carry Mark-of-the-Web, which RemoteSigned refuses for worker.ps1 at runtime.
Get-ChildItem -LiteralPath $toolRoot -Recurse -File|Where-Object{$_.FullName -notlike (Join-Path $toolRoot '.venv\*')}|Unblock-File
$venvPython=Join-Path $toolRoot '.venv\Scripts\python.exe'
# A .venv copied from another folder or computer points at a missing interpreter; rebuild it for this path.
if(Test-Path -LiteralPath $venvPython){try{& $venvPython -c 'import sys' 2>$null;$venvOk=$LASTEXITCODE -eq 0}catch{$venvOk=$false};if(-not $venvOk){Remove-Item -LiteralPath (Join-Path $toolRoot '.venv') -Recurse -Force}}
if(-not (Test-Path -LiteralPath $venvPython)){& $info.executable -m venv (Join-Path $toolRoot '.venv');if($LASTEXITCODE -ne 0){throw 'Could not create local virtual environment.'}}
& $venvPython -m pip install --no-index --find-links (Join-Path $toolRoot 'wheels') --require-hashes -r (Join-Path $toolRoot 'requirements.lock')
if($LASTEXITCODE -ne 0){throw 'Offline pinned dependency setup failed.'}
$bridge=Join-Path $toolRoot 'bridge.py'
if($RegisterCodex){& codex mcp add windows-ui-bridge -- $venvPython $bridge serve;if($LASTEXITCODE -ne 0){throw 'Codex MCP registration failed.'}}
if($RegisterClaude){& claude mcp add --transport stdio --scope user windows-ui-bridge -- $venvPython $bridge serve;if($LASTEXITCODE -ne 0){throw 'Claude Code MCP registration failed.'}}
[pscustomobject]@{ready=$true;toolRoot=$toolRoot;python=$venvPython;entryPoint=$bridge;executionPolicy="$policy";codexRegistered=[bool]$RegisterCodex;claudeRegistered=[bool]$RegisterClaude}|ConvertTo-Json

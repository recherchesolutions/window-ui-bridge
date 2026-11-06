param([string]$Version='0.1.0')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
# Only distributable source and the pinned wheel; never .venv, .state, caches or local MCP configuration.
$files='README.md','Setup.cmd','Setup.ps1','bridge.py','invoke_supervisor.py','uia3_worker.py','worker.ps1','smoke_test.py','test_fixture.ps1','requirements.txt','requirements.lock'
$name="windows-ui-bridge-v$Version"
$stage=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'));$pkg=Join-Path $stage $name
New-Item -ItemType Directory -Force (Join-Path $pkg 'wheels')|Out-Null
foreach($f in $files){Copy-Item -LiteralPath (Join-Path $root $f) -Destination $pkg}
Copy-Item -Path (Join-Path $root 'wheels\*.whl') -Destination (Join-Path $pkg 'wheels')
$out=Join-Path $root 'release';New-Item -ItemType Directory -Force $out|Out-Null
$zip=Join-Path $out "$name.zip";Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue
# Windows PowerShell 5.1 zips with backslash entry names; write standard '/' paths explicitly.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::Open($zip,'Create')
try{foreach($file in Get-ChildItem -LiteralPath $pkg -Recurse -File){$entry=$name+'/'+$file.FullName.Substring($pkg.Length+1).Replace('\','/');[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$file.FullName,$entry,'Optimal')}}finally{$archive.Dispose()}
Remove-Item -LiteralPath $stage -Recurse -Force
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
"$hash  $name.zip"|Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
[pscustomobject]@{zip=$zip;sha256=$hash}|ConvertTo-Json

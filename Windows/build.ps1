$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $repo 'dist\XHSLinkRepair-Windows'
New-Item -ItemType Directory -Force $out | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /codepage:65001 "/out:$out\小红书链接修复.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Xml.Linq.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll (Join-Path $PSScriptRoot 'Core.cs') (Join-Path $PSScriptRoot 'App.cs') (Join-Path $PSScriptRoot 'Tests.cs')
if ($LASTEXITCODE -ne 0) { throw '编译失败' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '使用说明.txt') -Destination $out
$test = Start-Process -FilePath (Join-Path $out '小红书链接修复.exe') -ArgumentList @('--self-test', ('"' + (Join-Path $out 'self-test.txt') + '"')) -WindowStyle Hidden -Wait -PassThru
if ($test.ExitCode -ne 0) { throw '自检失败，请查看 dist 中的 self-test.txt' }
Compress-Archive -Path "$out\*" -DestinationPath (Join-Path $repo 'dist\XHSLinkRepair-0.1.0-Windows-x64.zip') -Force
Write-Output "已生成：$out"

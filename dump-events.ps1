$ErrorActionPreference = 'Stop'
$exe = 'D:\dev\disk-monitor\src\cwatch\cwtdump.exe'
$out = 'D:\dev\disk-monitor\logs\cwtdump.txt'
$sec = 30

if (-not (Test-Path -LiteralPath $exe)) { "missing: $exe"; exit 3 }

"running $exe $sec  (about $sec seconds) ..."
$lines = & $exe $sec 2>&1 | ForEach-Object { [string]$_ }
[IO.File]::WriteAllLines($out, $lines, (New-Object Text.UTF8Encoding($false)))
$lines | ForEach-Object { $_ }
""
"saved: $out"

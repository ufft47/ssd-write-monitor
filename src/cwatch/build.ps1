# build.ps1 - 用 Windows 內建的 csc（.NET Framework 4.8）編譯 collector，不需要安裝 .NET SDK
param(
    [string]$ProjectDir = 'D:\dev\disk-monitor\src\cwatch'
)

$ErrorActionPreference = 'Stop'
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "找不到 csc.exe：$csc" }

Push-Location $ProjectDir
try {
    & $csc /nologo /optimize+ /target:exe /platform:x64 /out:cwatch.exe `
        /r:lib\Microsoft.Diagnostics.Tracing.TraceEvent.dll `
        /r:lib\Microsoft.Diagnostics.FastSerialization.dll `
        CWatch.cs 2>&1 | ForEach-Object { $_ }
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "編譯失敗，csc exit=$code" }
    Copy-Item 'lib\*.dll' . -Force
    Write-Output ("built: {0} ({1:N0} KB)" -f (Join-Path $ProjectDir 'cwatch.exe'), ((Get-Item 'cwatch.exe').Length / 1KB))
} finally {
    Pop-Location
}

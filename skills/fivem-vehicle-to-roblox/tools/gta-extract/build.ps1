# Compile gta-extract sous Windows (PowerShell). Nécessite le SDK .NET 8+ et git.
# Résultat : .\bin\gta-extract.exe
$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$CwRepo = if ($env:CW_REPO) { $env:CW_REPO } else { "https://github.com/dexyfex/CodeWalker" }
$CwRef = if ($env:CW_REF) { $env:CW_REF } else { "485d56bec00262ed7fa472261cce7bbc6202b96e" }
$Cache = Join-Path $Here ".cache/CodeWalker"
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet introuvable : installez le SDK .NET 8 (winget install Microsoft.DotNet.SDK.8)"
}
if (-not (Test-Path (Join-Path $Cache ".git"))) { git clone --filter=blob:none $CwRepo $Cache }
git -C $Cache fetch --quiet origin $CwRef
git -C $Cache checkout --quiet $CwRef
dotnet build (Join-Path $Here "GtaExtract.csproj") -c Release -o (Join-Path $Here "bin") -nologo -v quiet
Write-Host "OK : $Here\bin\gta-extract.exe"

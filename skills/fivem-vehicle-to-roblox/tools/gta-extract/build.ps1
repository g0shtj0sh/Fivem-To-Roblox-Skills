# Compile gta-extract sous Windows (PowerShell). Nécessite le SDK .NET 8+ et git.
# Résultat : .\bin\gta-extract.exe
#
# Note : on NE met PAS $ErrorActionPreference = "Stop" globalement, car git et dotnet
# écrivent des messages d'avancement normaux sur stderr, ce que PowerShell transforme
# alors en exception (NativeCommandError) même quand la commande a réussi.
# On vérifie $LASTEXITCODE à la place.

$ErrorActionPreference = "Continue"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$CwRepo = if ($env:CW_REPO) { $env:CW_REPO } else { "https://github.com/dexyfex/CodeWalker" }
$CwRef = if ($env:CW_REF) { $env:CW_REF } else { "485d56bec00262ed7fa472261cce7bbc6202b96e" }
$Cache = Join-Path $Here ".cache/CodeWalker"

function Invoke-Native {
    param([string]$What, [string]$Exe, [string[]]$CmdArgs)
    & $Exe @CmdArgs 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "$What a echoue (code $LASTEXITCODE)" }
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet introuvable : installez le SDK .NET 8 (winget install Microsoft.DotNet.SDK.8)"
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git introuvable : installez Git (winget install Git.Git)"
}

if (-not (Test-Path (Join-Path $Cache ".git"))) {
    Write-Host "Clonage de CodeWalker (MIT) dans .cache/CodeWalker ..."
    Invoke-Native "git clone" "git" @("clone", "--filter=blob:none", "--no-checkout", $CwRepo, $Cache)
}
Write-Host "Recuperation de la revision $CwRef ..."
Invoke-Native "git fetch" "git" @("-C", $Cache, "fetch", "--quiet", "origin", $CwRef)
Invoke-Native "git checkout" "git" @("-C", $Cache, "checkout", "--quiet", $CwRef)

Write-Host "Compilation ..."
Invoke-Native "dotnet build" "dotnet" @("build", (Join-Path $Here "GtaExtract.csproj"), "-c", "Release", "-o", (Join-Path $Here "bin"), "-nologo", "-v", "quiet")

$exe = Join-Path $Here "bin\gta-extract.exe"
if (-not (Test-Path $exe)) { throw "compilation terminee mais $exe est absent" }
Write-Host "OK : $exe"

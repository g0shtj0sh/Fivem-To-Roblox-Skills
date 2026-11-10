@echo off
rem ---------------------------------------------------------------------------
rem  Serveur d'assets GTA V pour le skill fivem-vehicle-to-roblox.
rem  Detecte GTA V, compile l'extracteur si besoin, puis sert les textures et
rem  sons du jeu de base sur http://127.0.0.1:27300/mcp (localhost uniquement).
rem
rem  Usage :  start-server.bat [port] [chemin\vers\GTA V]
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

set PORT=%1
if "%PORT%"=="" set PORT=27300
set GAME=%~2

echo === Serveur d'assets GTA V ===
echo.

rem --- Python -----------------------------------------------------------------
set PY=
for %%P in (python.exe py.exe) do (
  if not defined PY (
    where %%P >nul 2>nul && set PY=%%P
  )
)
if not defined PY (
  echo ERREUR : Python introuvable. Installez Python 3.10+ ^(winget install Python.Python.3.12^).
  pause
  exit /b 1
)

rem --- dependances ------------------------------------------------------------
%PY% -c "import PIL, numpy" >nul 2>nul
if errorlevel 1 (
  echo Installation de Pillow et numpy ...
  %PY% -m pip install --quiet --disable-pip-version-check pillow numpy
  if errorlevel 1 (
    echo ERREUR : installation des dependances impossible.
    pause
    exit /b 1
  )
)

rem --- extracteur -------------------------------------------------------------
if not exist "..\gta-extract\bin\gta-extract.exe" (
  echo Compilation de gta-extract ^(CodeWalker.Core, premiere fois seulement^) ...
  powershell -NoProfile -ExecutionPolicy Bypass -File "..\gta-extract\build.ps1"
  if errorlevel 1 (
    echo.
    echo ERREUR : compilation de gta-extract impossible.
    echo Verifiez que le SDK .NET 8+ et git sont installes :
    echo    winget install Microsoft.DotNet.SDK.8
    echo    winget install Git.Git
    pause
    exit /b 1
  )
)

rem --- lancement --------------------------------------------------------------
echo.
if "%GAME%"=="" (
  %PY% server.py --port %PORT% --prewarm
) else (
  %PY% server.py --port %PORT% --prewarm --game "%GAME%"
)

if errorlevel 1 (
  echo.
  echo Le serveur s'est arrete sur une erreur.
  pause
)
endlocal

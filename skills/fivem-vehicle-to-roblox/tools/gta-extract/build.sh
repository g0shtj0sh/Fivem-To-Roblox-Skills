#!/usr/bin/env bash
# Compile gta-extract (Linux / macOS / WSL). Nécessite le SDK .NET 8+ et git.
# Résultat : ./bin/gta-extract.dll   (lancer avec : dotnet ./bin/gta-extract.dll ...)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CW_REPO="${CW_REPO:-https://github.com/dexyfex/CodeWalker}"
# Commit de CodeWalker de référence (CW_REF=master pour la dernière version).
CW_REF="${CW_REF:-485d56bec00262ed7fa472261cce7bbc6202b96e}"
CACHE="$HERE/.cache/CodeWalker"

if ! command -v dotnet >/dev/null 2>&1; then
  echo "dotnet introuvable. Installez le SDK .NET 8 :" >&2
  echo "  Ubuntu/Debian : sudo apt-get install -y dotnet-sdk-8.0" >&2
  echo "  Autres        : https://dotnet.microsoft.com/download" >&2
  exit 1
fi

if [ ! -d "$CACHE/.git" ]; then
  mkdir -p "$HERE/.cache"
  git clone --filter=blob:none "$CW_REPO" "$CACHE"
fi
git -C "$CACHE" fetch --quiet origin "$CW_REF" 2>/dev/null || true
git -C "$CACHE" checkout --quiet "$CW_REF" 2>/dev/null || git -C "$CACHE" checkout --quiet FETCH_HEAD

dotnet build "$HERE/GtaExtract.csproj" -c Release -o "$HERE/bin" -nologo -v quiet
echo "OK : $HERE/bin/gta-extract.dll"

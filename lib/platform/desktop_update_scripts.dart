class DesktopUpdateScripts {
  static const String macOS = r'''
#!/bin/sh
set -eu
payload="$1"
target="$2"
app_pid="$3"
manual="$4"
log_dir="${HOME:-/tmp}/Library/Logs"
mkdir -p "$log_dir" 2>/dev/null || true
log="$log_dir/AlembicUpdater.log"
exec >>"$log" 2>&1
echo "Starting Alembic update"
echo "Payload: $payload"
echo "Target: $target"
echo "App pid: $app_pid"
while kill -0 "$app_pid" 2>/dev/null; do
  sleep 1
done
if [ ! -f "$payload" ]; then
  echo "Update payload does not exist"
  [ -n "$manual" ] && open "$manual" || true
  exit 1
fi
staging="$(mktemp -d "${TMPDIR:-/tmp}/alembic-update.XXXXXX")"
backup="${target}.previous"
if ! ditto -x -k "$payload" "$staging"; then
  echo "Failed to extract update payload"
  [ -n "$manual" ] && open "$manual" || true
  exit 1
fi
app="$(find "$staging" -maxdepth 3 \( -name "Alembic.app" -o -name "alembic.app" \) -type d | head -n 1)"
if [ -z "$app" ]; then
  app="$(find "$staging" -maxdepth 3 -iname "*.app" -type d | head -n 1)"
fi
if [ -z "$app" ]; then
  echo "Alembic app bundle was not found in the update payload"
  [ -n "$manual" ] && open "$manual" || true
  exit 1
fi
rm -rf "$backup"
if [ -d "$target" ] && ! mv "$target" "$backup"; then
  echo "Cannot replace the installed app; opening the manual installer"
  rm -rf "$staging"
  [ -n "$manual" ] && open "$manual" || true
  exit 1
fi
if ! mv "$app" "$target"; then
  echo "Failed to move update app into place"
  rm -rf "$target"
  if [ -d "$backup" ]; then
    mv "$backup" "$target"
  fi
  [ -n "$manual" ] && open "$manual" || true
  exit 1
fi
if ! open "$target"; then
  echo "Could not launch the updated app; restoring the previous installation"
  rm -rf "$target"
  if [ -d "$backup" ]; then
    mv "$backup" "$target"
  fi
  rm -rf "$staging"
  [ -n "$manual" ] && open "$manual" || true
  exit 1
fi
rm -rf "$backup" "$staging"
echo "Alembic update installed"
''';
  static const String windows = r'''
param(
  [string]$Payload,
  [string]$Target,
  [int]$AppPid,
  [string]$Manual
)
$ErrorActionPreference = "Stop"
$Log = Join-Path $env:TEMP "AlembicUpdater.log"
$Backup = ""
Start-Transcript -Path $Log -Append | Out-Null
try {
  Write-Output "Starting Alembic update"
  Write-Output "Payload: $Payload"
  Write-Output "Target: $Target"
  Write-Output "App pid: $AppPid"
  while (Get-Process -Id $AppPid -ErrorAction SilentlyContinue) {
    Start-Sleep -Seconds 1
  }
  if (!(Test-Path -LiteralPath $Payload)) {
    throw "Update payload does not exist"
  }
  $Staging = Join-Path $env:TEMP ("alembic-update-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $Staging -Force | Out-Null
  Expand-Archive -LiteralPath $Payload -DestinationPath $Staging -Force
  $Exe = Get-ChildItem -Path $Staging -Recurse -Filter "Alembic.exe" | Select-Object -First 1
  if ($null -eq $Exe) {
    throw "Alembic.exe was not found in update payload"
  }
  $Source = $Exe.Directory.FullName
  $Parent = Split-Path -Parent $Target
  $Leaf = Split-Path -Leaf $Target
  $Backup = Join-Path $Parent "$Leaf.previous"
  Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $Target) {
    # Inno Setup's uninstaller is installed separately from the app zip.
    Get-ChildItem -LiteralPath $Target -File -Filter "unins*" |
      Copy-Item -Destination $Source -Force
    Move-Item -LiteralPath $Target -Destination $Backup -Force
  }
  New-Item -ItemType Directory -Path $Target -Force | Out-Null
  Copy-Item -Path (Join-Path $Source "*") -Destination $Target -Recurse -Force
  Start-Process -FilePath (Join-Path $Target "Alembic.exe")
  Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue
} catch {
  if (![string]::IsNullOrWhiteSpace($Backup) -and (Test-Path -LiteralPath $Backup)) {
    Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $Backup -Destination $Target -Force
  }
  if (![string]::IsNullOrWhiteSpace($Manual)) {
    Start-Process $Manual
  }
  exit 1
} finally {
  Stop-Transcript | Out-Null
}
''';
}

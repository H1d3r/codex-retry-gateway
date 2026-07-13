param(
  [string]$StateRoot = "$HOME\.codex-retry-gateway",
  [string]$CodexConfigPath = "$HOME\.codex\config.toml"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$paths = Get-GatewayStatePaths -StateRoot $StateRoot
$state = Read-JsonFile -Path $paths.StatePath
if ($null -eq $state) {
  throw "Install state file was not found: $($paths.StatePath)"
}

$backupPath = [string]$state.latest_backup_path
if ([string]::IsNullOrWhiteSpace($backupPath) -or -not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
  throw "A restorable backup file was not found: $backupPath"
}

& (Join-Path $PSScriptRoot "stop-gateway.ps1") -StateRoot $StateRoot -Quiet
Copy-Item -LiteralPath $backupPath -Destination $CodexConfigPath -Force
Remove-Item -LiteralPath $paths.StatePath -Force -ErrorAction SilentlyContinue

Write-Output "Restored Codex config"
Write-Output "config=$CodexConfigPath"
Write-Output "restored_from=$backupPath"

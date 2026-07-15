param(
  [string]$StateRoot = "$HOME\.codex-retry-gateway",
  [string]$ConfigPath,
  [string]$LogPath,
  [switch]$RestartIfRunning
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$paths = Get-GatewayStatePaths -StateRoot $StateRoot
if (-not $ConfigPath) {
  $ConfigPath = $paths.ConfigPath
}
if (-not $LogPath) {
  $LogPath = $paths.LogPath
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "Gateway config file was not found: $ConfigPath"
}

Ensure-Directory -Path (Split-Path -Parent $LogPath)

$gatewayConfig = Read-JsonFile -Path $ConfigPath
if ($null -eq $gatewayConfig) {
  throw "Gateway config file could not be read: $ConfigPath"
}

if (Test-Path -LiteralPath $paths.PidPath) {
  $existingPidRaw = (Get-Content -LiteralPath $paths.PidPath -Raw).Trim()
  if ($existingPidRaw) {
    $existingPid = [int]$existingPidRaw
    if (Test-ProcessAlive -ProcessId $existingPid) {
      if (Test-GatewayProcessIdentity -ProcessId $existingPid -GatewayConfig $gatewayConfig) {
        if ($RestartIfRunning) {
          & (Join-Path $PSScriptRoot "stop-gateway.ps1") -StateRoot $StateRoot -Quiet
        } else {
          Write-Output "Gateway is already running. PID=$existingPid"
          exit 0
        }
      } else {
        Remove-Item -LiteralPath $paths.PidPath -Force
      }
    } else {
      Remove-Item -LiteralPath $paths.PidPath -Force
    }
  }
}

$gatewayRoot = Get-GatewayRoot
$gatewayEntry = Join-Path $gatewayRoot "gateway.mjs"
if (-not (Test-Path -LiteralPath $gatewayEntry)) {
  throw "Gateway entry file was not found: $gatewayEntry"
}

$nodeCommand = (Get-Command node -ErrorAction Stop).Source
$argumentLine = @(
  ('"{0}"' -f $gatewayEntry),
  "--config",
  ('"{0}"' -f $ConfigPath),
  "--log",
  ('"{0}"' -f $LogPath)
) -join " "

$process = Start-Process `
  -FilePath $nodeCommand `
  -ArgumentList $argumentLine `
  -WorkingDirectory $gatewayRoot `
  -WindowStyle Hidden `
  -PassThru

try {
  Set-Content -LiteralPath $paths.PidPath -Value $process.Id -NoNewline
  Start-Sleep -Milliseconds 300
  if ($process.HasExited) {
    $logTail = if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath -Tail 20 | Out-String } else { "" }
    throw "Gateway exited right after startup. PID=$($process.Id)`n$logTail"
  }

  $null = Wait-GatewayHealth `
    -ListenHost ([string]$gatewayConfig.listen_host) `
    -ListenPort ([int]$gatewayConfig.listen_port) `
    -HealthPath ([string]$gatewayConfig.health_path) `
    -ExpectedProcessId $process.Id
} catch {
  $startError = $_
  try {
    Stop-FailedGatewayStart -ProcessId $process.Id -PidPath $paths.PidPath
  } catch {
  }
  throw $startError
}

Write-Output ("Gateway started. PID={0}. Listen=http://{1}:{2}" -f $process.Id, $gatewayConfig.listen_host, $gatewayConfig.listen_port)

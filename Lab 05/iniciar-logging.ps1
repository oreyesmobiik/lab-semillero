$labDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $labDir 'ejecucion-lab05.log'

if (-not (Test-Path $labDir)) {
    New-Item -ItemType Directory -Path $labDir -Force | Out-Null
}

if (-not (Test-Path $logFile)) {
    New-Item -ItemType File -Path $logFile -Force | Out-Null
}

try {
    Stop-Transcript | Out-Null
} catch {
}

Start-Transcript -Path $logFile -Append -Force | Out-Null
Write-Host "Transcript activo en: $logFile"

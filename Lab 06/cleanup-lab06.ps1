[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$ResourceGroupName = "az104-rg06",
    [switch]$DeleteIfMissing = $false
)

$ErrorActionPreference = "Stop"

try {
    $null = Get-AzSubscription -ErrorAction Stop | Select-Object -First 1
} catch {
    $details = $_.Exception.Message
    throw "No se pudo validar sesion/modulos Az. Ejecuta Connect-AzAccount. Si persiste, actualiza/reinstala Az (ejemplo: Update-Module Az -Force). Detalle: $details"
}

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue

if (-not $rg) {
    if ($DeleteIfMissing) {
        Write-Host "El recurso $ResourceGroupName no existe. No hay nada que eliminar."
        return
    }

    throw "El resource group '$ResourceGroupName' no existe en la suscripcion activa."
}

if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Eliminar resource group y todos sus recursos")) {
    Remove-AzResourceGroup -Name $ResourceGroupName -Force -AsJob | Out-Null
    Write-Host "Se envio la eliminacion de '$ResourceGroupName' en segundo plano."
    Write-Host "Puedes revisar progreso con: Get-AzResourceGroup -Name $ResourceGroupName"
}

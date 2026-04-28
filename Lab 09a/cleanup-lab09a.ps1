[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$ResourceGroupName = "az104-rg9",
    [switch]$DeleteIfMissing = $false
)

$ErrorActionPreference = "Stop"

if (-not (Get-AzContext)) {
    throw "No hay contexto de Azure activo. Ejecuta Connect-AzAccount primero."
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

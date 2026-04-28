param(
    [string]$ResourceGroupName = "az104-rg9",
    [string]$Location = "eastus"
)

$ErrorActionPreference = "Stop"

if (-not (Get-AzContext)) {
    throw "No hay contexto de Azure activo. Ejecuta Connect-AzAccount primero."
}

$suffix = Get-Random -Minimum 10000 -Maximum 99999
$planName = "az104-plan$suffix"
$appName = "az104web$suffix"
$slotName = "staging"

Write-Host "Creando RG: $ResourceGroupName en $Location"
New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force | Out-Null

Write-Host "Creando App Service Plan Linux P1v3: $planName"
New-AzAppServicePlan -ResourceGroupName $ResourceGroupName -Name $planName -Location $Location -Tier PremiumV3 -WorkerSize Medium -NumberofWorkers 1 -Linux | Out-Null

Write-Host "Creando Web App PHP 8.2: $appName"
New-AzWebApp -ResourceGroupName $ResourceGroupName -Name $appName -Location $Location -AppServicePlan $planName -RuntimeStack "PHP|8.2" | Out-Null

Write-Host "Creando slot: $slotName"
New-AzWebAppSlot -ResourceGroupName $ResourceGroupName -Name $appName -Slot $slotName | Out-Null

Write-Host "Configurando Deployment Center en slot staging con External Git"
$subId = (Get-AzContext).Subscription.Id
$path = "/subscriptions/$subId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$appName/slots/$slotName/sourcecontrols/web?api-version=2022-03-01"
$payload = @{
    properties = @{
        repoUrl = "https://github.com/Azure-Samples/php-docs-hello-world"
        branch = "master"
        isManualIntegration = $true
    }
} | ConvertTo-Json -Depth 6
Invoke-AzRestMethod -Method PUT -Path $path -Payload $payload | Out-Null

Write-Host "Haciendo swap de staging a production"
Switch-AzWebAppSlot -ResourceGroupName $ResourceGroupName -Name $appName -SourceSlotName $slotName -DestinationSlotName "production" | Out-Null

$prodHost = (Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $appName).DefaultHostName
$stagingHost = (Get-AzWebAppSlot -ResourceGroupName $ResourceGroupName -Name $appName -Slot $slotName).DefaultHostName

Write-Host ""
Write-Host "Lab 09a tareas 1-4 completadas"
Write-Host "Produccion: https://$prodHost"
Write-Host "Staging: https://$stagingHost"
Write-Host ""
Write-Host "Tarea 5 (autoscale + load test) se completa en portal:"
Write-Host "1) App Service plan > Scale out > Automatic > Maximum burst = 2"
Write-Host "2) Web App > Diagnose and solve problems > Create Load Test"
Write-Host "3) URL objetivo = https://$prodHost"

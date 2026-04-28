param(
    [string]$ResourceGroupName = "az104-rg4",
    [string]$Location = "eastus",
    [string]$PublicDnsZoneName = "contoso.com",
    [string]$PrivateDnsZoneName = "private.contoso.com"
)

$ErrorActionPreference = "Stop"

if (-not (Get-AzContext)) {
    throw "No hay contexto de Azure activo. Ejecuta Connect-AzAccount primero."
}

& "$PSScriptRoot\iniciar-logging.ps1"

Write-Host "Iniciando LAB 04 en RG=$ResourceGroupName, region=$Location"
New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force | Out-Null

$coreSubnet1 = New-AzVirtualNetworkSubnetConfig -Name "SharedServicesSubnet" -AddressPrefix "10.20.10.0/24"
$coreSubnet2 = New-AzVirtualNetworkSubnetConfig -Name "DatabaseSubnet" -AddressPrefix "10.20.20.0/24"
$coreVnet = Get-AzVirtualNetwork -Name "CoreServicesVnet" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $coreVnet) {
    $coreVnet = New-AzVirtualNetwork -Name "CoreServicesVnet" -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix "10.20.0.0/16" -Subnet $coreSubnet1, $coreSubnet2
    Write-Host "CoreServicesVnet creado"
} else {
    Write-Host "CoreServicesVnet ya existia"
}

$manSubnet1 = New-AzVirtualNetworkSubnetConfig -Name "SensorSubnet1" -AddressPrefix "10.30.20.0/24"
$manSubnet2 = New-AzVirtualNetworkSubnetConfig -Name "SensorSubnet2" -AddressPrefix "10.30.21.0/24"
$manVnet = Get-AzVirtualNetwork -Name "ManufacturingVnet" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $manVnet) {
    $manVnet = New-AzVirtualNetwork -Name "ManufacturingVnet" -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix "10.30.0.0/16" -Subnet $manSubnet1, $manSubnet2
    Write-Host "ManufacturingVnet creado"
} else {
    Write-Host "ManufacturingVnet ya existia"
}

$asg = Get-AzApplicationSecurityGroup -ResourceGroupName $ResourceGroupName -Name "asg-web" -ErrorAction SilentlyContinue
if (-not $asg) {
    $asg = New-AzApplicationSecurityGroup -ResourceGroupName $ResourceGroupName -Name "asg-web" -Location $Location
    Write-Host "ASG asg-web creado"
} else {
    Write-Host "ASG asg-web ya existia"
}

$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name "myNSGSecure" -ErrorAction SilentlyContinue
if (-not $nsg) {
    $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Location $Location -Name "myNSGSecure"
    Write-Host "NSG myNSGSecure creado"
} else {
    Write-Host "NSG myNSGSecure ya existia"
}

if (-not ($nsg.SecurityRules | Where-Object Name -eq "AllowASG")) {
    $nsg = Add-AzNetworkSecurityRuleConfig -Name "AllowASG" -NetworkSecurityGroup $nsg -Description "Allow ASG web traffic" -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceApplicationSecurityGroup $asg -SourcePortRange "*" -DestinationAddressPrefix "*" -DestinationPortRange "80","443"
}
if (-not ($nsg.SecurityRules | Where-Object Name -eq "DenyInternetOutbound")) {
    $nsg = Add-AzNetworkSecurityRuleConfig -Name "DenyInternetOutbound" -NetworkSecurityGroup $nsg -Description "Deny internet outbound" -Access Deny -Protocol "*" -Direction Outbound -Priority 4096 -SourceAddressPrefix "*" -SourcePortRange "*" -DestinationAddressPrefix "Internet" -DestinationPortRange "*"
}
$nsg = Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg
Write-Host "Reglas NSG configuradas"

$coreVnet = Get-AzVirtualNetwork -Name "CoreServicesVnet" -ResourceGroupName $ResourceGroupName
Set-AzVirtualNetworkSubnetConfig -Name "SharedServicesSubnet" -VirtualNetwork $coreVnet -AddressPrefix "10.20.10.0/24" -NetworkSecurityGroup $nsg | Out-Null
$coreVnet | Set-AzVirtualNetwork | Out-Null
Write-Host "NSG asociado a SharedServicesSubnet"

try {
    $publicZone = New-AzDnsZone -Name $PublicDnsZoneName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
} catch {
    if ($_.Exception.Message -like "*is not available*") {
        $PublicDnsZoneName = "contoso$((Get-Random -Minimum 10000 -Maximum 99999)).com"
        $publicZone = New-AzDnsZone -Name $PublicDnsZoneName -ResourceGroupName $ResourceGroupName
    } else {
        throw
    }
}

$rs = Get-AzDnsRecordSet -ZoneName $PublicDnsZoneName -ResourceGroupName $ResourceGroupName -Name "www" -RecordType A -ErrorAction SilentlyContinue
if (-not $rs) {
    $rs = New-AzDnsRecordSet -Name "www" -RecordType A -ZoneName $PublicDnsZoneName -ResourceGroupName $ResourceGroupName -Ttl 1
}
Add-AzDnsRecordConfig -RecordSet $rs -Ipv4Address "10.1.1.4" | Set-AzDnsRecordSet | Out-Null
Write-Host "Zona DNS publica y registro A creados"

if ($PrivateDnsZoneName -eq "private.contoso.com" -and $PublicDnsZoneName -ne "contoso.com") {
    $PrivateDnsZoneName = "private.$PublicDnsZoneName"
}

$privateZone = Get-AzPrivateDnsZone -Name $PrivateDnsZoneName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $privateZone) {
    $privateZone = New-AzPrivateDnsZone -Name $PrivateDnsZoneName -ResourceGroupName $ResourceGroupName
}

$link = Get-AzPrivateDnsVirtualNetworkLink -ZoneName $PrivateDnsZoneName -ResourceGroupName $ResourceGroupName -Name "manufacturing-link" -ErrorAction SilentlyContinue
if (-not $link) {
    New-AzPrivateDnsVirtualNetworkLink -ZoneName $PrivateDnsZoneName -ResourceGroupName $ResourceGroupName -Name "manufacturing-link" -VirtualNetworkId $manVnet.Id -EnableRegistration:$false | Out-Null
}

$privateRecord = Get-AzPrivateDnsRecordSet -Name "sensorvm" -RecordType A -ZoneName $PrivateDnsZoneName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $privateRecord) {
    $privateRecord = New-AzPrivateDnsRecordSet -Name "sensorvm" -RecordType A -ZoneName $PrivateDnsZoneName -ResourceGroupName $ResourceGroupName -Ttl 1
}
Add-AzPrivateDnsRecordConfig -RecordSet $privateRecord -Ipv4Address "10.1.1.4" | Set-AzPrivateDnsRecordSet | Out-Null
Write-Host "Zona DNS privada, link y registro creados"

$ns = (Get-AzDnsZone -Name $PublicDnsZoneName -ResourceGroupName $ResourceGroupName).NameServers | Select-Object -First 1
$summary = @(
    "`$ResourceGroupName = '$ResourceGroupName'",
    "`$Location = '$Location'",
    "`$PublicDnsZoneName = '$PublicDnsZoneName'",
    "`$PrivateDnsZoneName = '$PrivateDnsZoneName'",
    "`$PublicNameServer = '$ns'"
)
$summary | Set-Content -Path "$PSScriptRoot\lab04-vars.ps1" -Encoding UTF8

Write-Host ""
Write-Host "LAB 04 completado"
Write-Host "Comando de validacion publica DNS: nslookup www.$PublicDnsZoneName $ns"
Write-Host "Variables en: $PSScriptRoot\lab04-vars.ps1"

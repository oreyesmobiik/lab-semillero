param(
    [string]$ResourceGroupName = "az104-rg05",
    [string]$Location = "eastus2",
    [string]$AdminUsername = "localadmin",
    [securestring]$AdminPassword,
    [string]$VmSize = "Standard_D2s_v3"
)

$ErrorActionPreference = "Stop"

if (-not (Get-AzContext)) {
    throw "No hay contexto de Azure activo. Ejecuta Connect-AzAccount primero."
}

& "$PSScriptRoot\iniciar-logging.ps1"

function New-RandomPassword {
    param([int]$Length = 16)

    $upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lower = "abcdefghijkmnpqrstuvwxyz"
    $digits = "23456789"
    $symbols = "!@#$%*+-_?"
    $all = $upper + $lower + $digits + $symbols

    $chars = @(
        ($upper.ToCharArray() | Get-Random)
        ($lower.ToCharArray() | Get-Random)
        ($digits.ToCharArray() | Get-Random)
        ($symbols.ToCharArray() | Get-Random)
    )

    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars += ($all.ToCharArray() | Get-Random)
    }

    -join ($chars | Sort-Object { Get-Random })
}

$generatedPassword = $null
if (-not $AdminPassword) {
    $generatedPassword = New-RandomPassword
    $AdminPassword = ConvertTo-SecureString $generatedPassword -AsPlainText -Force
}

$coreVnetName = "CoreServicesVnet"
$coreSubnetName = "Core"
$coreAddressPrefix = "10.0.0.0/16"
$coreSubnetPrefix = "10.0.0.0/24"
$perimeterSubnetName = "Perimeter"
$perimeterSubnetPrefix = "10.0.1.0/24"
$coreVmName = "CoreServicesVM"

$manufacturingVnetName = "ManufacturingVnet"
$manufacturingSubnetName = "Manufacturing"
$manufacturingAddressPrefix = "172.16.0.0/16"
$manufacturingSubnetPrefix = "172.16.0.0/24"
$manufacturingVmName = "ManufacturingVM"

$routeTableName = "rt-CoreServices"
$routeName = "PerimetertoCore"
$routeDestination = "10.0.0.0/16"
$routeNextHop = "10.0.1.7"

function Resolve-AvailableVmSize {
    param(
        [string]$Region,
        [string[]]$PreferredSizes
    )

    $availableSizes = @()

    try {
        $availableSizes = (Get-AzVMSize -Location $Region -ErrorAction Stop).Name
    } catch {
        if (Get-Command Get-AzComputeResourceSku -ErrorAction SilentlyContinue) {
            try {
                $availableSizes = Get-AzComputeResourceSku |
                    Where-Object {
                        $_.ResourceType -eq "virtualMachines" -and
                        $_.Locations -contains $Region -and
                        ($_.Restrictions.Count -eq 0)
                    } |
                    Select-Object -ExpandProperty Name -Unique
            } catch {
                Write-Warning "No se pudo consultar disponibilidad de tamanos en '$Region'. Se intentara con '$($PreferredSizes[0])'."
                return $PreferredSizes[0]
            }
        } else {
            Write-Warning "Get-AzVMSize -Location no esta disponible y no se encontro Get-AzComputeResourceSku. Se intentara con '$($PreferredSizes[0])'."
            return $PreferredSizes[0]
        }
    }

    if (-not $availableSizes -or $availableSizes.Count -eq 0) {
        Write-Warning "No fue posible determinar tamanos disponibles en '$Region'. Se intentara con '$($PreferredSizes[0])'."
        return $PreferredSizes[0]
    }

    foreach ($size in $PreferredSizes) {
        if ($availableSizes -contains $size) {
            return $size
        }
    }

    throw "No se encontro ningun tamano de VM disponible en la region '$Region'. Probados: $($PreferredSizes -join ', ')"
}

function Test-IsVmCapacityError {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $message = $ErrorRecord.Exception.Message
    $capacityPatterns = @(
        "not available in location",
        "SkuNotAvailable",
        "OperationNotAllowed",
        "exceeds quota",
        "quota",
        "overconstrained",
        "Allocation failed"
    )

    foreach ($pattern in $capacityPatterns) {
        if ($message -like "*$pattern*") {
            return $true
        }
    }

    return $false
}

function Ensure-Vnet {
    param(
        [string]$Name,
        [string]$AddressPrefix,
        [string]$SubnetName,
        [string]$SubnetPrefix
    )

    $vnet = Get-AzVirtualNetwork -Name $Name -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $vnet) {
        $subnet = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetPrefix
        $vnet = New-AzVirtualNetwork -Name $Name -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix $AddressPrefix -Subnet $subnet
        Write-Host "VNet $Name creada"
    } else {
        Write-Host "VNet $Name ya existia"
    }

    return $vnet
}

function Add-CompatibleVnetPeering {
    param(
        [string]$PeeringName,
        [Microsoft.Azure.Commands.Network.Models.PSVirtualNetwork]$SourceVnet,
        [string]$RemoteVnetId
    )

    $cmd = Get-Command Add-AzVirtualNetworkPeering -ErrorAction Stop
    $params = @{
        Name = $PeeringName
        VirtualNetwork = $SourceVnet
        RemoteVirtualNetworkId = $RemoteVnetId
    }

    if ($cmd.Parameters.ContainsKey("AllowVirtualNetworkAccess")) {
        $params.AllowVirtualNetworkAccess = $true
    }
    if ($cmd.Parameters.ContainsKey("AllowForwardedTraffic")) {
        $params.AllowForwardedTraffic = $true
    }

    Add-AzVirtualNetworkPeering @params | Out-Null
}

function Ensure-VM {
    param(
        [string]$VmName,
        [Microsoft.Azure.Commands.Network.Models.PSVirtualNetwork]$Vnet,
        [string]$SubnetName,
        [pscredential]$Credential,
        [string[]]$VmSizesToTry
    )

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction SilentlyContinue
    if ($vm) {
        Write-Host "VM $VmName ya existia"
        return [pscustomobject]@{
            Vm = $vm
            VmSize = $vm.HardwareProfile.VmSize
        }
    }

    $subnet = $Vnet.Subnets | Where-Object Name -eq $SubnetName
    if (-not $subnet) {
        throw "No se encontro el subnet '$SubnetName' en la VNet '$($Vnet.Name)'."
    }

    $nicName = "$VmName-nic"
    $nic = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $nicName -ErrorAction SilentlyContinue
    if (-not $nic) {
        $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId $subnet.Id
    }

    foreach ($candidateSize in $VmSizesToTry) {
        try {
            Write-Host "Intentando crear VM $VmName con tamano $candidateSize"

            $vmConfig = New-AzVMConfig -VMName $VmName -VMSize $candidateSize
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $VmName -Credential $Credential -ProvisionVMAgent -EnableAutoUpdate
            $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName "MicrosoftWindowsServer" -Offer "WindowsServer" -Skus "2022-datacenter-azure-edition" -Version "latest"
            $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
            $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable

            New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig | Out-Null
            Write-Host "VM $VmName creada con tamano $candidateSize"

            return [pscustomobject]@{
                Vm = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName)
                VmSize = $candidateSize
            }
        } catch {
            if (Test-IsVmCapacityError -ErrorRecord $_) {
                Write-Warning "No se pudo crear $VmName con $candidateSize. Se intentara el siguiente tamano. Detalle: $($_.Exception.Message)"
            } else {
                throw
            }
        }
    }

    throw "No fue posible crear la VM '$VmName' en '$Location' con los tamanos probados: $($VmSizesToTry -join ', ')"
}

Write-Host "Iniciando LAB 05 en RG=$ResourceGroupName, region=$Location"
New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force | Out-Null

$preferredVmSizes = @(
    $VmSize
    "Standard_B1s"
    "Standard_B1ms"
    "Standard_DS1_v2"
    "Standard_B2s"
    "Standard_B2ms"
    "Standard_D2as_v5"
)
$preferredVmSizes = $preferredVmSizes | Select-Object -Unique
Write-Host "Tamano de VM solicitado: $VmSize"
Write-Host "Orden de intento de tamanos en ${Location}: $($preferredVmSizes -join ', ')"

$coreVnet = Ensure-Vnet -Name $coreVnetName -AddressPrefix $coreAddressPrefix -SubnetName $coreSubnetName -SubnetPrefix $coreSubnetPrefix
$manufacturingVnet = Ensure-Vnet -Name $manufacturingVnetName -AddressPrefix $manufacturingAddressPrefix -SubnetName $manufacturingSubnetName -SubnetPrefix $manufacturingSubnetPrefix

$cred = [pscredential]::new($AdminUsername, $AdminPassword)
$coreVmResult = Ensure-VM -VmName $coreVmName -Vnet $coreVnet -SubnetName $coreSubnetName -Credential $cred -VmSizesToTry $preferredVmSizes
$manufacturingVmResult = Ensure-VM -VmName $manufacturingVmName -Vnet $manufacturingVnet -SubnetName $manufacturingSubnetName -Credential $cred -VmSizesToTry $preferredVmSizes
$coreVm = $coreVmResult.Vm
$manufacturingVm = $manufacturingVmResult.Vm
$coreVmSelectedSize = $coreVmResult.VmSize
$manufacturingVmSelectedSize = $manufacturingVmResult.VmSize
Write-Host "Tamano usado por ${coreVmName}: $coreVmSelectedSize"
Write-Host "Tamano usado por ${manufacturingVmName}: $manufacturingVmSelectedSize"

$nw = Get-AzNetworkWatcher -ResourceGroupName "NetworkWatcherRG" -Name "NetworkWatcher_$Location" -ErrorAction SilentlyContinue
if (-not $nw) {
    $nw = New-AzNetworkWatcher -Name "NetworkWatcher_$Location" -ResourceGroupName "NetworkWatcherRG" -Location $Location
}

$preCheck = Test-AzNetworkWatcherConnectivity -NetworkWatcher $nw -SourceId $coreVm.Id -DestinationId $manufacturingVm.Id -DestinationPort 3389
Write-Host "Prueba de conectividad antes de peering: $($preCheck.ConnectionStatus)"

$peerAName = "$coreVnetName-to-$manufacturingVnetName"
$peerBName = "$manufacturingVnetName-to-$coreVnetName"

$peerA = Get-AzVirtualNetworkPeering -Name $peerAName -VirtualNetworkName $coreVnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $peerA) {
    Add-CompatibleVnetPeering -PeeringName $peerAName -SourceVnet $coreVnet -RemoteVnetId $manufacturingVnet.Id
    Write-Host "Peering $peerAName creado"
}

$peerB = Get-AzVirtualNetworkPeering -Name $peerBName -VirtualNetworkName $manufacturingVnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $peerB) {
    Add-CompatibleVnetPeering -PeeringName $peerBName -SourceVnet $manufacturingVnet -RemoteVnetId $coreVnet.Id
    Write-Host "Peering $peerBName creado"
}

$coreVnet = Get-AzVirtualNetwork -Name $coreVnetName -ResourceGroupName $ResourceGroupName
$manufacturingVnet = Get-AzVirtualNetwork -Name $manufacturingVnetName -ResourceGroupName $ResourceGroupName

$postCheck = Test-AzNetworkWatcherConnectivity -NetworkWatcher $nw -SourceId $coreVm.Id -DestinationId $manufacturingVm.Id -DestinationPort 3389
Write-Host "Prueba de conectividad despues de peering: $($postCheck.ConnectionStatus)"

$coreVmCurrent = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $coreVmName
$coreNicId = $null

if ($coreVmCurrent.NetworkProfile -and $coreVmCurrent.NetworkProfile.NetworkInterfaces -and $coreVmCurrent.NetworkProfile.NetworkInterfaces.Count -gt 0) {
    $coreNicId = $coreVmCurrent.NetworkProfile.NetworkInterfaces[0].Id
}

if (-not $coreNicId -and $coreVm.NetworkProfile -and $coreVm.NetworkProfile.NetworkInterfaces -and $coreVm.NetworkProfile.NetworkInterfaces.Count -gt 0) {
    $coreNicId = $coreVm.NetworkProfile.NetworkInterfaces[0].Id
}

if ($coreNicId) {
    $coreNic = Get-AzNetworkInterface -ResourceId $coreNicId
} else {
    $coreNic = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name "$coreVmName-nic" -ErrorAction SilentlyContinue
    if (-not $coreNic) {
        throw "No se pudo obtener la NIC para $coreVmName."
    }
}

$corePrivateIp = $coreNic.IpConfigurations[0].PrivateIpAddress

$runCommand = @"
Test-NetConnection $corePrivateIp -Port 3389 | Select-Object ComputerName, RemoteAddress, RemotePort, TcpTestSucceeded
"@
$runResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $manufacturingVmName -CommandId 'RunPowerShellScript' -ScriptString $runCommand
Write-Host "Resultado Run Command desde ${manufacturingVmName} hacia ${coreVmName}:"
Write-Host $runResult.Value[0].Message

$perimeterSubnet = $coreVnet.Subnets | Where-Object Name -eq $perimeterSubnetName
if (-not $perimeterSubnet) {
    Add-AzVirtualNetworkSubnetConfig -Name $perimeterSubnetName -VirtualNetwork $coreVnet -AddressPrefix $perimeterSubnetPrefix | Out-Null
    $coreVnet = Set-AzVirtualNetwork -VirtualNetwork $coreVnet
    Write-Host "Subnet $perimeterSubnetName creado"
}

$routeTable = Get-AzRouteTable -Name $routeTableName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $routeTable) {
    $routeTable = New-AzRouteTable -Name $routeTableName -ResourceGroupName $ResourceGroupName -Location $Location -DisableBgpRoutePropagation
    Write-Host "Route table $routeTableName creado"
}

if (-not ($routeTable.Routes | Where-Object Name -eq $routeName)) {
    Add-AzRouteConfig -Name $routeName -AddressPrefix $routeDestination -NextHopType VirtualAppliance -NextHopIpAddress $routeNextHop -RouteTable $routeTable | Out-Null
    $routeTable = Set-AzRouteTable -RouteTable $routeTable
    Write-Host "Ruta $routeName creada"
}

$coreVnet = Get-AzVirtualNetwork -Name $coreVnetName -ResourceGroupName $ResourceGroupName
$perimeterSubnet = $coreVnet.Subnets | Where-Object Name -eq $perimeterSubnetName
if (-not $perimeterSubnet) {
    throw "No se encontro el subnet $perimeterSubnetName en $coreVnetName despues de crearlo."
}

if ($perimeterSubnet.RouteTable -eq $null -or $perimeterSubnet.RouteTable.Id -ne $routeTable.Id) {
    Set-AzVirtualNetworkSubnetConfig -Name $perimeterSubnetName -VirtualNetwork $coreVnet -AddressPrefix $perimeterSubnetPrefix -RouteTable $routeTable | Out-Null
    $coreVnet | Set-AzVirtualNetwork | Out-Null
    Write-Host "Route table asociado a subnet $perimeterSubnetName"
}

$summary = @(
    "`$ResourceGroupName = '$ResourceGroupName'",
    "`$Location = '$Location'",
    "`$CoreVnetName = '$coreVnetName'",
    "`$ManufacturingVnetName = '$manufacturingVnetName'",
    "`$CoreVmName = '$coreVmName'",
    "`$ManufacturingVmName = '$manufacturingVmName'",
    "`$CoreVmSize = '$coreVmSelectedSize'",
    "`$ManufacturingVmSize = '$manufacturingVmSelectedSize'",
    "`$CoreVmPrivateIp = '$corePrivateIp'",
    "`$RouteTableName = '$routeTableName'"
)
$summary | Set-Content -Path "$PSScriptRoot\lab05-vars.ps1" -Encoding UTF8

Write-Host ""
Write-Host "LAB 05 completado"
Write-Host "Conectividad antes peering: $($preCheck.ConnectionStatus)"
Write-Host "Conectividad despues peering: $($postCheck.ConnectionStatus)"
Write-Host "CoreServicesVM IP privada: $corePrivateIp"
if ($generatedPassword) {
    Write-Host "Password generado para '$AdminUsername': $generatedPassword"
}
Write-Host "Variables en: $PSScriptRoot\lab05-vars.ps1"

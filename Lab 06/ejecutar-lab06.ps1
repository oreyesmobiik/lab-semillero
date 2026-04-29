param(
    [string]$ResourceGroupName = "az104-rg06",
    [string]$Location = "eastus2",
    [string]$AdminUsername = "localadmin",
    [securestring]$AdminPassword,
    [string]$VmSize = "Standard_B1s"
)

$ErrorActionPreference = "Stop"

try {
    $null = Get-AzSubscription -ErrorAction Stop | Select-Object -First 1
} catch {
    $details = $_.Exception.Message
    throw "No se pudo validar sesion/modulos Az. Ejecuta Connect-AzAccount. Si persiste, actualiza/reinstala Az (ejemplo: Update-Module Az -Force). Detalle: $details"
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

function Get-RegionCandidateVmSizes {
    param(
        [string]$Region,
        [string[]]$CandidateVmSizes
    )

    if (-not (Get-Command Get-AzComputeResourceSku -ErrorAction SilentlyContinue)) {
        return $CandidateVmSizes
    }

    try {
        $availableSkus = Get-AzComputeResourceSku |
            Where-Object {
                $_.ResourceType -eq "virtualMachines" -and
                $_.Locations -contains $Region -and
                ($_.Restrictions.Count -eq 0)
            } |
            Select-Object -ExpandProperty Name -Unique

        return @($CandidateVmSizes | Where-Object { $availableSkus -contains $_ })
    } catch {
        Write-Warning "No se pudo consultar SKUs para '$Region'. Se intentaran los tamanos candidatos configurados. Detalle: $($_.Exception.Message)"
        return $CandidateVmSizes
    }
}

function Resolve-DeploymentLocation {
    param(
        [string]$PreferredLocation,
        [string[]]$FallbackLocations,
        [string[]]$CandidateVmSizes,
        [int]$RequiredCoreHeadroom = 3
    )

    if (-not (Get-Command Get-AzComputeResourceSku -ErrorAction SilentlyContinue)) {
        Write-Warning "No se encontro Get-AzComputeResourceSku. Se utilizara la region solicitada: $PreferredLocation"
        return $PreferredLocation
    }

    $regionsToTry = @($PreferredLocation)
    $regionsToTry += $FallbackLocations | Where-Object { $_ -and $_ -ne $PreferredLocation }

    foreach ($region in $regionsToTry) {
        try {
            $coresUsage = Get-AzVMUsage -Location $region -ErrorAction SilentlyContinue | Where-Object { $_.Name.Value -eq "cores" }
            if ($coresUsage) {
                $remainingCores = [int]$coresUsage.Limit - [int]$coresUsage.CurrentValue
                if ($remainingCores -lt $RequiredCoreHeadroom) {
                    Write-Warning "Se omite region '$region' por cuota insuficiente de vCPU. Disponible=$remainingCores, requerido=$RequiredCoreHeadroom"
                    continue
                }
            }

            $availableSkus = Get-RegionCandidateVmSizes -Region $region -CandidateVmSizes $CandidateVmSizes

            if (-not $availableSkus -or $availableSkus.Count -eq 0) {
                continue
            }

            $matchingSize = $availableSkus | Select-Object -First 1
            if ($matchingSize) {
                if ($region -ne $PreferredLocation) {
                    Write-Warning "No se encontro capacidad util en '$PreferredLocation'. Se usara '$region'."
                }
                return $region
            }
        } catch {
            Write-Warning "No se pudo validar SKUs para '$region'. Detalle: $($_.Exception.Message)"
        }
    }

    Write-Warning "No se encontro region valida por pre-chequeo. Se utilizara la solicitada: $PreferredLocation"
    return $PreferredLocation
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
        [string]$NicName,
        [pscredential]$Credential,
        [string[]]$VmSizesToTry
    )

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction SilentlyContinue
    if ($vm) {
        Write-Host "VM $VmName ya existia"
        $nicExisting = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $NicName -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Vm = $vm
            Nic = $nicExisting
            VmSize = $vm.HardwareProfile.VmSize
        }
    }

    $subnet = $Vnet.Subnets | Where-Object Name -eq $SubnetName
    if (-not $subnet) {
        throw "No se encontro el subnet '$SubnetName' en la VNet '$($Vnet.Name)'."
    }

    $nic = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $NicName -ErrorAction SilentlyContinue
    if (-not $nic) {
        $nic = New-AzNetworkInterface -Name $NicName -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId $subnet.Id
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
                Nic = (Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $NicName)
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

function Invoke-ConfigureWebContent {
    param(
        [string]$VmName,
        [string]$IndexMessage,
        [string]$PathPrefix,
        [string]$PathMessage
    )

    $escapedIndex = $IndexMessage.Replace("'", "''")
    $script = @"
Install-WindowsFeature -Name Web-Server -IncludeManagementTools
Set-Content -Path 'C:\inetpub\wwwroot\index.html' -Value '$escapedIndex' -Encoding UTF8
"@

    if ($PathPrefix -and $PathMessage) {
        $escapedPath = $PathMessage.Replace("'", "''")
        $script += @"
New-Item -ItemType Directory -Path 'C:\inetpub\wwwroot\$PathPrefix' -Force | Out-Null
Set-Content -Path 'C:\inetpub\wwwroot\$PathPrefix\index.html' -Value '$escapedPath' -Encoding UTF8
"@
    }

    Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VmName -CommandId 'RunPowerShellScript' -ScriptString $script | Out-Null
}

$vnetName = "az104-06-vnet1"
$subnet0Name = "subnet0"
$subnet1Name = "subnet1"
$subnet2Name = "subnet2"
$appGwSubnetName = "subnet-appgw"

$vm0Name = "az104-06-vm0"
$vm1Name = "az104-06-vm1"
$vm2Name = "az104-06-vm2"

$nic0Name = "az104-06-nic0"
$nic1Name = "az104-06-nic1"
$nic2Name = "az104-06-nic2"

$nsgName = "az104-06-nsg"

$lbName = "az104-lb"
$lbFrontendName = "az104-fe"
$lbPublicIpName = "az104-lbpip"
$lbBackendName = "az104-be"
$lbProbeName = "az104-hp"
$lbRuleName = "az104-lbrule"

$appGwName = "az104-appgw"
$appGwPublicIpName = "az104-gwpip"
$appGwBackendName = "az104-appgwbe"
$appGwImageBackendName = "az104-imagebe"
$appGwVideoBackendName = "az104-videobe"
$appGwFrontendIpName = "az104-feip"
$appGwFrontendPortName = "az104-feport"
$appGwHttpSettingName = "az104-http"
$appGwListenerName = "az104-listener"
$appGwRuleName = "az104-gwrule"
$appGwUrlMapName = "az104-urlmap"

$preferredVmSizes = @(
    $VmSize
    "Standard_B1ls"
    "Standard_B1s"
    "Standard_B1ms"
    "Standard_D1_v2"
    "Standard_D2s_v5"
    "Standard_D2s_v4"
    "Standard_D2as_v5"
    "Standard_DS1_v2"
    "Standard_B2s"
    "Standard_B2ms"
)
$preferredVmSizes = $preferredVmSizes | Select-Object -Unique

$fallbackLocations = @("centralus", "westus2", "southcentralus", "eastus", "northcentralus", "westus")

$requestedLocation = $Location
$existingVnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($existingVnet) {
    if ($existingVnet.Location -ne $Location) {
        Write-Warning "La VNet existente '$vnetName' esta en '$($existingVnet.Location)'. Se usara esa region para mantener consistencia."
    }
    $Location = $existingVnet.Location

    $existingRegionCandidateSizes = Get-RegionCandidateVmSizes -Region $Location -CandidateVmSizes $preferredVmSizes
    if (-not $existingRegionCandidateSizes -or $existingRegionCandidateSizes.Count -eq 0) {
        throw "La infraestructura existente del Lab 06 esta anclada a '$Location', pero no hay SKUs candidatos viables en esa region para este despliegue. Ejecuta cleanup-lab06.ps1 y vuelve a correr el lab para permitir fallback a otra region."
    }
} else {
    $Location = Resolve-DeploymentLocation -PreferredLocation $Location -FallbackLocations $fallbackLocations -CandidateVmSizes $preferredVmSizes -RequiredCoreHeadroom 3
}

Write-Host "Iniciando LAB 06 en RG=$ResourceGroupName, region solicitada=$requestedLocation, region efectiva=$Location"
New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force | Out-Null

Write-Host "Tamano de VM solicitado: $VmSize"
Write-Host "Orden de intento de tamanos en ${Location}: $($preferredVmSizes -join ', ')"

$vnet = $existingVnet
if (-not $vnet) {
    $s0 = New-AzVirtualNetworkSubnetConfig -Name $subnet0Name -AddressPrefix "10.60.0.0/24"
    $s1 = New-AzVirtualNetworkSubnetConfig -Name $subnet1Name -AddressPrefix "10.60.1.0/24"
    $s2 = New-AzVirtualNetworkSubnetConfig -Name $subnet2Name -AddressPrefix "10.60.2.0/24"
    $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix "10.60.0.0/16" -Subnet $s0, $s1, $s2
    Write-Host "VNet $vnetName creada"
} else {
    Write-Host "VNet $vnetName ya existia"
}

$nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $nsg) {
    $nsg = New-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName -Location $Location
}
if (-not ($nsg.SecurityRules | Where-Object Name -eq "Allow-HTTP")) {
    $nsg = Add-AzNetworkSecurityRuleConfig -Name "Allow-HTTP" -NetworkSecurityGroup $nsg -Description "Allow HTTP" -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix "*" -SourcePortRange "*" -DestinationAddressPrefix "*" -DestinationPortRange "80"
}
if (-not ($nsg.SecurityRules | Where-Object Name -eq "Allow-RDP")) {
    $nsg = Add-AzNetworkSecurityRuleConfig -Name "Allow-RDP" -NetworkSecurityGroup $nsg -Description "Allow RDP" -Access Allow -Protocol Tcp -Direction Inbound -Priority 110 -SourceAddressPrefix "*" -SourcePortRange "*" -DestinationAddressPrefix "*" -DestinationPortRange "3389"
}
$nsg = Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg

$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName
foreach ($sn in @($subnet0Name, $subnet1Name, $subnet2Name)) {
    Set-AzVirtualNetworkSubnetConfig -Name $sn -VirtualNetwork $vnet -AddressPrefix ($vnet.Subnets | Where-Object Name -eq $sn).AddressPrefix -NetworkSecurityGroup $nsg | Out-Null
}
$vnet | Set-AzVirtualNetwork | Out-Null

$credPassword = $AdminPassword
$generatedPassword = $null
if (-not $credPassword) {
    $generatedPassword = New-RandomPassword
    $credPassword = ConvertTo-SecureString $generatedPassword -AsPlainText -Force
}
$cred = [pscredential]::new($AdminUsername, $credPassword)

$vm0 = Ensure-VM -VmName $vm0Name -Vnet $vnet -SubnetName $subnet0Name -NicName $nic0Name -Credential $cred -VmSizesToTry $preferredVmSizes
$vm1 = Ensure-VM -VmName $vm1Name -Vnet $vnet -SubnetName $subnet1Name -NicName $nic1Name -Credential $cred -VmSizesToTry $preferredVmSizes
$vm2 = Ensure-VM -VmName $vm2Name -Vnet $vnet -SubnetName $subnet2Name -NicName $nic2Name -Credential $cred -VmSizesToTry $preferredVmSizes

$vm0Size = $vm0.VmSize
$vm1Size = $vm1.VmSize
$vm2Size = $vm2.VmSize
Write-Host "Tamano usado por ${vm0Name}: $vm0Size"
Write-Host "Tamano usado por ${vm1Name}: $vm1Size"
Write-Host "Tamano usado por ${vm2Name}: $vm2Size"

Invoke-ConfigureWebContent -VmName $vm0Name -IndexMessage "Hello World from az104-06-vm0" -PathPrefix "" -PathMessage ""
Invoke-ConfigureWebContent -VmName $vm1Name -IndexMessage "Hello World from az104-06-vm1" -PathPrefix "image" -PathMessage "Image server from az104-06-vm1"
Invoke-ConfigureWebContent -VmName $vm2Name -IndexMessage "Hello World from az104-06-vm2" -PathPrefix "video" -PathMessage "Video server from az104-06-vm2"
Write-Host "IIS y contenido web configurados en las 3 VMs"

$lbPublicIp = Get-AzPublicIpAddress -Name $lbPublicIpName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $lbPublicIp) {
    $lbPublicIp = New-AzPublicIpAddress -Name $lbPublicIpName -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard
}

$lb = Get-AzLoadBalancer -Name $lbName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $lb) {
    $fe = New-AzLoadBalancerFrontendIpConfig -Name $lbFrontendName -PublicIpAddress $lbPublicIp
    $be = New-AzLoadBalancerBackendAddressPoolConfig -Name $lbBackendName
    $lb = New-AzLoadBalancer -Name $lbName -ResourceGroupName $ResourceGroupName -Location $Location -Sku Standard -FrontendIpConfiguration $fe -BackendAddressPool $be
    Write-Host "Load Balancer $lbName creado"
}

$lb = Get-AzLoadBalancer -Name $lbName -ResourceGroupName $ResourceGroupName
if (-not ($lb.Probes | Where-Object Name -eq $lbProbeName)) {
    Add-AzLoadBalancerProbeConfig -Name $lbProbeName -LoadBalancer $lb -Protocol Tcp -Port 80 -IntervalInSeconds 5 -ProbeCount 2 | Out-Null
}
if (-not ($lb.LoadBalancingRules | Where-Object Name -eq $lbRuleName)) {
    $feRef = $lb.FrontendIpConfigurations | Where-Object Name -eq $lbFrontendName
    $beRef = $lb.BackendAddressPools | Where-Object Name -eq $lbBackendName
    $probeRef = $lb.Probes | Where-Object Name -eq $lbProbeName
    Add-AzLoadBalancerRuleConfig -Name $lbRuleName -LoadBalancer $lb -Protocol Tcp -FrontendPort 80 -BackendPort 80 -FrontendIpConfiguration $feRef -BackendAddressPool $beRef -Probe $probeRef -IdleTimeoutInMinutes 4 -EnableTcpReset:$false | Out-Null
}
$lb = Set-AzLoadBalancer -LoadBalancer $lb

$lb = Get-AzLoadBalancer -Name $lbName -ResourceGroupName $ResourceGroupName
$lbBackendPool = $lb.BackendAddressPools | Where-Object Name -eq $lbBackendName
foreach ($nicName in @($nic0Name, $nic1Name)) {
    $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName
    $ipConfig = $nic.IpConfigurations[0]
    $currentPools = @($ipConfig.LoadBalancerBackendAddressPools)
    if (-not ($currentPools | Where-Object Id -eq $lbBackendPool.Id)) {
        Set-AzNetworkInterfaceIpConfig -Name $ipConfig.Name -NetworkInterface $nic -SubnetId $ipConfig.Subnet.Id -PrivateIpAddress $ipConfig.PrivateIpAddress -LoadBalancerBackendAddressPool ($currentPools + $lbBackendPool) | Out-Null
        $nic | Set-AzNetworkInterface | Out-Null
    }
}
Write-Host "Backend pool del Load Balancer asociado a nic0 y nic1"

$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName
$appGwSubnet = $vnet.Subnets | Where-Object Name -eq $appGwSubnetName
if (-not $appGwSubnet) {
    Add-AzVirtualNetworkSubnetConfig -Name $appGwSubnetName -VirtualNetwork $vnet -AddressPrefix "10.60.3.224/27" | Out-Null
    $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
    Write-Host "Subnet $appGwSubnetName creado"
}

$appGwPublicIp = Get-AzPublicIpAddress -Name $appGwPublicIpName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $appGwPublicIp) {
    $appGwPublicIp = New-AzPublicIpAddress -Name $appGwPublicIpName -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard
}

$appGw = Get-AzApplicationGateway -Name $appGwName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $appGw) {
    $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName
    $appGwSubnet = $vnet.Subnets | Where-Object Name -eq $appGwSubnetName

    $nic1Ip = (Get-AzNetworkInterface -Name $nic1Name -ResourceGroupName $ResourceGroupName).IpConfigurations[0].PrivateIpAddress
    $nic2Ip = (Get-AzNetworkInterface -Name $nic2Name -ResourceGroupName $ResourceGroupName).IpConfigurations[0].PrivateIpAddress

    $beMain = New-AzApplicationGatewayBackendAddressPool -Name $appGwBackendName -BackendIPAddresses $nic1Ip, $nic2Ip
    $beImage = New-AzApplicationGatewayBackendAddressPool -Name $appGwImageBackendName -BackendIPAddresses $nic1Ip
    $beVideo = New-AzApplicationGatewayBackendAddressPool -Name $appGwVideoBackendName -BackendIPAddresses $nic2Ip

    $feIp = New-AzApplicationGatewayFrontendIPConfig -Name $appGwFrontendIpName -PublicIPAddress $appGwPublicIp
    $fePort = New-AzApplicationGatewayFrontendPort -Name $appGwFrontendPortName -Port 80
    $httpSetting = New-AzApplicationGatewayBackendHttpSettings -Name $appGwHttpSettingName -Port 80 -Protocol Http -CookieBasedAffinity Disabled -RequestTimeout 30
    $listener = New-AzApplicationGatewayHttpListener -Name $appGwListenerName -Protocol Http -FrontendIPConfiguration $feIp -FrontendPort $fePort

    $pathImage = New-AzApplicationGatewayPathRuleConfig -Name "images" -Paths "/image/*" -BackendAddressPool $beImage -BackendHttpSettings $httpSetting
    $pathVideo = New-AzApplicationGatewayPathRuleConfig -Name "videos" -Paths "/video/*" -BackendAddressPool $beVideo -BackendHttpSettings $httpSetting
    $urlPathMap = New-AzApplicationGatewayUrlPathMapConfig -Name $appGwUrlMapName -PathRule $pathImage, $pathVideo -DefaultBackendAddressPool $beMain -DefaultBackendHttpSettings $httpSetting

    $rule = New-AzApplicationGatewayRequestRoutingRule -Name $appGwRuleName -RuleType PathBasedRouting -Priority 10 -HttpListener $listener -UrlPathMap $urlPathMap
    $sku = New-AzApplicationGatewaySku -Name Standard_v2 -Tier Standard_v2 -Capacity 2
    $gatewayIpConfig = New-AzApplicationGatewayIPConfiguration -Name "appGwIpConfig" -Subnet $appGwSubnet

    $appGw = New-AzApplicationGateway -Name $appGwName -ResourceGroupName $ResourceGroupName -Location $Location -BackendAddressPools $beMain, $beImage, $beVideo -BackendHttpSettingsCollection $httpSetting -FrontendIPConfigurations $feIp -GatewayIPConfigurations $gatewayIpConfig -FrontendPorts $fePort -HttpListeners $listener -RequestRoutingRules $rule -Sku $sku
    Write-Host "Application Gateway $appGwName creado"
}

$lbPublicIp = Get-AzPublicIpAddress -Name $lbPublicIpName -ResourceGroupName $ResourceGroupName
$appGwPublicIp = Get-AzPublicIpAddress -Name $appGwPublicIpName -ResourceGroupName $ResourceGroupName

$summary = @(
    "`$ResourceGroupName = '$ResourceGroupName'",
    "`$Location = '$Location'",
    "`$VnetName = '$vnetName'",
    "`$LoadBalancerName = '$lbName'",
    "`$LoadBalancerPublicIp = '$($lbPublicIp.IpAddress)'",
    "`$ApplicationGatewayName = '$appGwName'",
    "`$ApplicationGatewayPublicIp = '$($appGwPublicIp.IpAddress)'",
    "`$Vm0Name = '$vm0Name'",
    "`$Vm1Name = '$vm1Name'",
    "`$Vm2Name = '$vm2Name'",
    "`$Vm0Size = '$vm0Size'",
    "`$Vm1Size = '$vm1Size'",
    "`$Vm2Size = '$vm2Size'"
)
$summary | Set-Content -Path "$PSScriptRoot\lab06-vars.ps1" -Encoding UTF8

Write-Host ""
Write-Host "LAB 06 completado"
Write-Host "Load Balancer URL de prueba: http://$($lbPublicIp.IpAddress)"
Write-Host "Application Gateway /image/: http://$($appGwPublicIp.IpAddress)/image/"
Write-Host "Application Gateway /video/: http://$($appGwPublicIp.IpAddress)/video/"
if ($generatedPassword) {
    Write-Host "Password generado para '$AdminUsername': $generatedPassword"
}
Write-Host "Variables en: $PSScriptRoot\lab06-vars.ps1"

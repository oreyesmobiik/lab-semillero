# lab-semillero

Repositorio de automatizaciones para laboratorios AZ-104 usando Azure PowerShell.

El enfoque de este repo es:
- Ejecutar laboratorios de forma reproducible.
- Mantener scripts idempotentes (si un recurso ya existe, se reutiliza cuando aplica).
- Guardar variables de salida para facilitar validaciones.
- Incluir cleanup por laboratorio para controlar costos.

## Estructura actual

- Lab 04
- Lab 05
- Lab 09a

Cada laboratorio incluye, segun corresponda:
- ejecutar-labXX.ps1
- cleanup-labXX.ps1
- iniciar-logging.ps1
- labXX-vars.ps1

## Prerrequisitos

1. Tener sesion activa en Azure:

    Connect-AzAccount

2. Tener modulo Az instalado/importado.
3. Ejecutar scripts desde PowerShell con permisos suficientes.
4. Revisar cuotas y disponibilidad regional (especialmente en Free Trial).

## Flujo recomendado de uso

1. Ir a la carpeta del laboratorio.
2. Ejecutar script principal.
3. Validar resultados en salida y en archivo de variables.
4. Cuando termines, ejecutar cleanup.

Ejemplo:

    cd "Lab 05"
    .\ejecutar-lab05.ps1 -Location eastus2
    .\cleanup-lab05.ps1 -Confirm:$false

## Laboratorio 04 - Virtual Networking, NSG y DNS

Script principal:
- Lab 04/ejecutar-lab04.ps1

Que implementa:
- Resource Group del lab.
- VNets: CoreServicesVnet y ManufacturingVnet.
- ASG (asg-web).
- NSG (myNSGSecure) con reglas:
  - AllowASG (inbound TCP 80/443 desde ASG).
  - DenyInternetOutbound.
- Asociacion de NSG a SharedServicesSubnet.
- DNS publico:
  - Zona publica.
  - Registro A www.
- DNS privado:
  - Zona privada.
  - VNet link.
  - Registro A sensorvm.

Salida importante:
- Lab 04/lab04-vars.ps1 con RG, region, zonas DNS y nameserver.

Puntos a considerar:
- Si el nombre de zona publica no esta disponible, el script genera un nombre alterno aleatorio.
- Es buena practica validar DNS con nslookup al terminar.

Cleanup:
- Lab 04/cleanup-lab04.ps1

## Laboratorio 05 - Intersite Connectivity

Script principal:
- Lab 05/ejecutar-lab05.ps1

Que implementa:
- Resource Group del lab.
- VNet CoreServicesVnet con subnet Core.
- VNet ManufacturingVnet con subnet Manufacturing.
- VMs:
  - CoreServicesVM
  - ManufacturingVM
- Prueba de conectividad con Network Watcher antes y despues de peering.
- Peering bidireccional entre VNets.
- Validacion desde VM con Run Command:
  - Test-NetConnection al puerto 3389.
- Subnet Perimeter en CoreServicesVnet.
- Route table rt-CoreServices.
- UDR PerimetertoCore hacia next hop virtual appliance 10.0.1.7.
- Asociacion de route table al subnet Perimeter.

Salida importante:
- Lab 05/lab05-vars.ps1 con datos de VNet, VM, tamanos usados, IP privada y route table.

Ajustes de compatibilidad ya incorporados:
- Fallback de tamano de VM para regiones/cuotas limitadas.
- Manejo de diferencias entre versiones de cmdlets Az.Network para peering.
- Resolucion robusta de NIC/IP privada en distintas versiones del modulo.
- Creacion de subnet usando Add-AzVirtualNetworkSubnetConfig y actualizacion con Set-AzVirtualNetworkSubnetConfig.

Puntos a considerar en Free Trial:
- Si eastus falla por capacidad, usar eastus2, centralus o westus2.
- Las cuotas pueden impedir ciertos SKUs; el script intenta varios tamanos.
- Mantener cleanup frecuente para liberar cuota y costo.

Cleanup:
- Lab 05/cleanup-lab05.ps1

## Laboratorio 09a - App Service y Deployment Slots

Script principal:
- Lab 09a/ejecutar-lab09a.ps1

Que implementa (tareas 1 a 4):
- Resource Group del lab.
- App Service Plan Linux (PremiumV3).
- Web App PHP 8.2.
- Slot staging.
- Configuracion de Deployment Center con repo externo.
- Swap de staging a production.

Salida importante:
- URL de produccion y staging en consola.

Punto a considerar:
- Tarea 5 (autoscale + load test) se termina en portal, no en script.

Cleanup:
- Lab 09a/cleanup-lab09a.ps1

## Mi punto de vista para mantener este repo escalable

1. Estandarizar parametros en todos los labs
- ResourceGroupName
- Location
- Prefijo de nombres

2. Agregar un patron comun de funciones reutilizables
- Ensure-ResourceGroup
- Ensure-Vnet
- Ensure-VM
- Ensure-RouteTable

3. Agregar un check de prerequisitos por script
- Validar sesion Az.
- Validar modulo minimo requerido.
- Mostrar version de modulos cargados.

4. Publicar una matriz de compatibilidad
- Versiones Az probadas.
- Regiones recomendadas por tipo de suscripcion.

5. Incluir una seccion de troubleshooting por laboratorio
- Error
- Causa probable
- Accion recomendada

## Troubleshooting rapido

1. Error de parser por variable seguida de dos puntos
- Usar delimitacion ${variable} en strings interpolados.

2. SKU de VM no disponible
- Cambiar region o usar tamanos alternos.

3. Parametro no encontrado en cmdlet
- Suele indicar diferencias de version de modulo Az.
- Evitar suposiciones y detectar parametros soportados en runtime.

4. Recursos parcialmente creados por una ejecucion fallida
- Reejecutar script (idempotencia) o limpiar con cleanup.

## Siguientes mejoras sugeridas

- Crear un script maestro en raiz para ejecutar laboratorios por numero.
- Exportar resumen final en JSON ademas de ps1-vars.
- Agregar validaciones automatas post-deploy (tests de conectividad y estado).

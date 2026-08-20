targetScope = 'resourceGroup'

@allowed([
  'create'
  'reuse'
])
param vnetMode string

@allowed([
  'create'
  'reuse'
])
param aksSubnetMode string

@allowed([
  'create'
  'reuse'
])
param postgresSubnetMode string

@allowed([
  'create'
  'reuse'
])
param privateEndpointSubnetMode string

@allowed([
  'create'
  'reuse'
])
param aksMode string

@allowed([
  'create'
  'reuse'
])
param postgresMode string

@allowed([
  'create'
  'reuse'
])
param redisMode string

param location string = resourceGroup().location
param vnetName string = ''
param vnetResourceId string = ''
param vnetAddressPrefix string = '10.42.0.0/16'
param aksSubnetName string = 'snet-aks-nodes'
param aksSubnetResourceId string = ''
param aksSubnetPrefix string = '10.42.0.0/20'
param postgresSubnetName string = 'snet-postgresql'
param postgresSubnetResourceId string = ''
param postgresSubnetPrefix string = '10.42.16.0/24'
param privateEndpointSubnetName string = 'snet-private-endpoints'
param privateEndpointSubnetResourceId string = ''
param privateEndpointSubnetPrefix string = '10.42.17.0/24'
param aksName string = ''
param aksResourceId string = ''
param aksDnsPrefix string = aksName
param aksNodeCount int = 3
param aksNodeVmSize string = 'Standard_D4ds_v5'

@allowed([
  'Free'
  'Standard'
  'Premium'
])
param aksSkuTier string = 'Standard'

param aksServiceCidr string = '10.43.0.0/16'
param aksDnsServiceIp string = '10.43.0.10'
param aksPodCidr string = '10.244.0.0/16'
param postgresName string = ''
param postgresResourceId string = ''
param postgresDatabaseName string = 'ghcp'
param postgresAdministratorLogin string = ''

@secure()
param postgresAdministratorPassword string = ''

param postgresSkuName string = 'Standard_D2ds_v5'
param postgresSkuTier string = 'GeneralPurpose'
param postgresStorageSizeGB int = 128

@allowed([
  'Disabled'
  'SameZone'
  'ZoneRedundant'
])
param postgresHighAvailability string = 'ZoneRedundant'

param redisName string = ''
param redisResourceId string = ''
param redisSkuName string = 'Balanced_B3'
param tags object = {}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = if (vnetMode == 'create') {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

var effectiveVnetName = vnetMode == 'create' ? vnetName : last(split(vnetResourceId, '/'))

resource aksSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (aksSubnetMode == 'create') {
  name: '${effectiveVnetName}/${aksSubnetName}'
  properties: {
    addressPrefix: aksSubnetPrefix
  }
  dependsOn: [
    vnet
  ]
}

resource postgresSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (postgresSubnetMode == 'create') {
  name: '${effectiveVnetName}/${postgresSubnetName}'
  properties: {
    addressPrefix: postgresSubnetPrefix
    delegations: [
      {
        name: 'postgresql-flexible-server'
        properties: {
          serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (privateEndpointSubnetMode == 'create') {
  name: '${effectiveVnetName}/${privateEndpointSubnetName}'
  properties: {
    addressPrefix: privateEndpointSubnetPrefix
    privateEndpointNetworkPolicies: 'Disabled'
  }
  dependsOn: [
    vnet
  ]
}

var effectiveVnetResourceId = vnetMode == 'create' ? vnet.id : vnetResourceId
var effectiveAksSubnetResourceId = aksSubnetMode == 'create' ? aksSubnet.id : aksSubnetResourceId
var effectivePostgresSubnetResourceId = postgresSubnetMode == 'create' ? postgresSubnet.id : postgresSubnetResourceId
var effectivePrivateEndpointSubnetResourceId = privateEndpointSubnetMode == 'create' ? privateEndpointSubnet.id : privateEndpointSubnetResourceId
var aksSubnetResourceIdParts = split(effectiveAksSubnetResourceId, '/')

resource aksControlPlaneIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (aksMode == 'create') {
  name: '${aksName}-control-plane'
  location: location
  tags: tags
}

// ARM does not preauthorize a system-assigned AKS identity for a custom subnet.
module aksSubnetRbac 'modules/aks-subnet-rbac.bicep' = if (aksMode == 'create') {
  name: '${aksName}-subnet-rbac'
  scope: resourceGroup(aksSubnetResourceIdParts[2], aksSubnetResourceIdParts[4])
  params: {
    vnetName: aksSubnetResourceIdParts[8]
    subnetName: aksSubnetResourceIdParts[10]
    principalId: aksControlPlaneIdentity!.properties.principalId
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2025-05-01' = if (aksMode == 'create') {
  name: aksName
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: aksSkuTier
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aksControlPlaneIdentity.id}': {}
    }
  }
  properties: {
    dnsPrefix: aksDnsPrefix
    enableRBAC: true
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    agentPoolProfiles: [
      {
        name: 'system'
        count: aksNodeCount
        vmSize: aksNodeVmSize
        osType: 'Linux'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: effectiveAksSubnetResourceId
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      serviceCidr: aksServiceCidr
      dnsServiceIP: aksDnsServiceIp
      podCidr: aksPodCidr
    }
  }
  dependsOn: [
    aksSubnetRbac
  ]
}

resource postgresPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (postgresMode == 'create') {
  name: '${postgresName}.private.postgres.database.azure.com'
  location: 'global'
  tags: tags
}

resource postgresPrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (postgresMode == 'create') {
  parent: postgresPrivateDnsZone
  name: '${postgresName}-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: effectiveVnetResourceId
    }
  }
}

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = if (postgresMode == 'create') {
  name: postgresName
  location: location
  tags: tags
  sku: {
    name: postgresSkuName
    tier: postgresSkuTier
  }
  properties: {
    version: '16'
    administratorLogin: postgresAdministratorLogin
    administratorLoginPassword: postgresAdministratorPassword
    network: {
      delegatedSubnetResourceId: effectivePostgresSubnetResourceId
      privateDnsZoneArmResourceId: postgresPrivateDnsZone.id
      publicNetworkAccess: 'Disabled'
    }
    highAvailability: {
      mode: postgresHighAvailability
    }
    storage: {
      autoGrow: 'Enabled'
      storageSizeGB: postgresStorageSizeGB
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
  }
  dependsOn: [
    postgresPrivateDnsLink
  ]
}

resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = if (postgresMode == 'create') {
  parent: postgres
  name: postgresDatabaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

resource redis 'Microsoft.Cache/redisEnterprise@2025-07-01' = if (redisMode == 'create') {
  name: redisName
  location: location
  tags: tags
  sku: {
    name: redisSkuName
  }
  properties: {
    encryption: {}
    highAvailability: 'Enabled'
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
  }
}

resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = if (redisMode == 'create') {
  parent: redis
  name: 'default'
  properties: {
    accessKeysAuthentication: 'Enabled'
    clientProtocol: 'Encrypted'
    clusteringPolicy: 'NoCluster'
    evictionPolicy: 'NoEviction'
    modules: []
    port: 10000
  }
}

var effectiveRedisResourceId = redisMode == 'create' ? redis.id : redisResourceId

resource redisPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.redis.azure.net'
  location: 'global'
  tags: tags
}

resource redisPrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: redisPrivateDnsZone
  name: '${effectiveVnetName}-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: effectiveVnetResourceId
    }
  }
}

resource redisPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: '${redisName}-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: effectivePrivateEndpointSubnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: '${redisName}-connection'
        properties: {
          privateLinkServiceId: effectiveRedisResourceId
          groupIds: [
            'redisEnterprise'
          ]
        }
      }
    ]
  }
  dependsOn: [
    redisDatabase
  ]
}

resource redisPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: redisPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'redis'
        properties: {
          privateDnsZoneId: redisPrivateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    redisPrivateDnsLink
  ]
}

output vnetId string = effectiveVnetResourceId
output aksSubnetId string = effectiveAksSubnetResourceId
output postgresSubnetId string = effectivePostgresSubnetResourceId
output privateEndpointSubnetId string = effectivePrivateEndpointSubnetResourceId
output aksId string = aksMode == 'create' ? aks.id : aksResourceId
output aksName string = aksMode == 'create' ? aks.name : last(split(aksResourceId, '/'))
output aksControlPlaneIdentityId string = aksMode == 'create' ? aksControlPlaneIdentity.id : ''
output postgresId string = postgresMode == 'create' ? postgres.id : postgresResourceId
output postgresHost string = postgresMode == 'create' ? '${postgresName}.postgres.database.azure.com' : ''
output postgresDatabase string = postgresDatabaseName
output redisId string = effectiveRedisResourceId
output redisHost string = redisMode == 'create' ? '${redisName}.${location}.redis.azure.net' : ''
output redisPort int = 10000
targetScope = 'resourceGroup'

param vnetName string
param subnetName string
param principalId string

var networkContributorRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4d97b98b-1d4f-4787-a291-c67834d212e7'
)

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: subnetName
}

resource networkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subnet.id, principalId, networkContributorRoleDefinitionId)
  scope: subnet
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: networkContributorRoleDefinitionId
  }
}
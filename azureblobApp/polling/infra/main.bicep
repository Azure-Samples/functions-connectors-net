targetScope = 'subscription'

@minLength(1)
@maxLength(64)
param environmentName string
@metadata({ azd: { type: 'location' } })
param location string
param connectorNamespaceLocation string = 'westcentralus'
@metadata({ azd: { type: 'principalId' } })
param userPrincipalId string = deployer().objectId
param monitoredContainerName string = 'connector-input'

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}
module connectorNamespace './connector-namespace.bicep' = {
  name: 'connector-namespace'
  scope: rg
  params: {
    name: 'cns-${resourceToken}'
    location: connectorNamespaceLocation
    tags: tags
    connectionName: 'cnsc-${resourceToken}-mi'
    userPrincipalId: userPrincipalId
  }
}
module monitoredStorageAccount 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'source-storage'
  scope: rg
  params: {
    name: 'stmon${resourceToken}'
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: { defaultAction: 'Allow' }
    minimumTlsVersion: 'TLS1_2'
    blobServices: { containers: [{ name: monitoredContainerName }] }
    roleAssignments: [
      {
        roleDefinitionIdOrName: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
        principalId: userPrincipalId
        principalType: 'User'
      }
      {
        roleDefinitionIdOrName: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
        principalId: connectorNamespace.outputs.principalId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}
output resourceGroupName string = rg.name
output functionAppName string = 'func-${resourceToken}'
output connectorNamespaceName string = connectorNamespace.outputs.name
output connectorNamespaceResourceId string = connectorNamespace.outputs.resourceId
output connectorNamespaceConnectionName string = connectorNamespace.outputs.connectionName
output CONNECTOR_NAMESPACE_LOCATION string = connectorNamespaceLocation
output monitoredStorageAccountName string = monitoredStorageAccount.outputs.name
output monitoredContainerName string = monitoredContainerName

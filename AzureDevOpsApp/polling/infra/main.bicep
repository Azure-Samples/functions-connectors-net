targetScope = 'subscription'

@minLength(1)
@maxLength(64)
param environmentName string
@metadata({ azd: { type: 'location' } })
param location string
param connectorNamespaceLocation string = 'westcentralus'
@metadata({ azd: { type: 'principalId' } })
@description('Existing developer/deployment principal object ID. Empty omits its grants.')
param userPrincipalId string = deployer().objectId

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: { 'azd-env-name': environmentName }
}
var token = uniqueString(rg.id)
module namespace './connector-namespace.bicep' = {
  name: 'namespace'
  scope: rg
  params: {
    name: 'cns-${token}'
    connectionName: 'cnsc-${token}'
    location: connectorNamespaceLocation
    tags: { 'azd-env-name': environmentName }
    connectorName: loadJsonContent('./scripts/polling-config.json').connectorName
    authenticationType: loadJsonContent('./scripts/polling-config.json').authenticationType
    userPrincipalId: userPrincipalId
  }
}
output resourceGroupName string = rg.name
output functionAppName string = 'func-${token}'
output connectorNamespaceName string = namespace.outputs.name
output connectorNamespaceResourceId string = namespace.outputs.resourceId
output connectorNamespaceConnectionName string = namespace.outputs.connectionName
output CONNECTOR_NAMESPACE_LOCATION string = connectorNamespaceLocation

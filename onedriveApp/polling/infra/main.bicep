targetScope = 'subscription'

@minLength(1)
@maxLength(64)
param environmentName string
@metadata({ azd: { type: 'location' } })
param location string
param connectorNamespaceLocation string = 'westcentralus'
@metadata({ azd: { type: 'principalId' } })
param userPrincipalId string = deployer().objectId

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
    connectionName: 'cnsc-${resourceToken}'
    userPrincipalId: userPrincipalId
  }
}
output resourceGroupName string = rg.name
output functionAppName string = 'func-${resourceToken}'
output connectorNamespaceName string = connectorNamespace.outputs.name
output connectorNamespaceResourceId string = connectorNamespace.outputs.resourceId
output connectorNamespaceConnectionName string = connectorNamespace.outputs.connectionName
output CONNECTOR_NAMESPACE_LOCATION string = connectorNamespaceLocation

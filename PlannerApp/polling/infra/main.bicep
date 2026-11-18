targetScope = 'subscription'

@minLength(1)
@maxLength(64)
param environmentName string
@metadata({ azd: { type: 'location' } })
param location string
param connectorNamespaceLocation string = 'westcentralus'
@metadata({ azd: { type: 'principalId' } })
param userPrincipalId string = deployer().objectId

var token = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}
module namespace './connector-namespace.bicep' = {
  scope: rg
  name: 'namespace'
  params: {
    name: 'cns-${token}'
    location: connectorNamespaceLocation
    tags: tags
    connectionName: 'cnsc-${token}'
    userPrincipalId: userPrincipalId
    connectorName: loadJsonContent('./scripts/polling-config.json').connectorName
    authenticationType: loadJsonContent('./scripts/polling-config.json').authenticationType
  }
}
output resourceGroupName string = rg.name
output functionAppName string = 'func-${token}'
output connectorNamespaceName string = namespace.outputs.name
output connectorNamespaceResourceId string = namespace.outputs.resourceId
output connectorNamespaceConnectionName string = namespace.outputs.connectionName
output CONNECTOR_NAMESPACE_LOCATION string = connectorNamespaceLocation

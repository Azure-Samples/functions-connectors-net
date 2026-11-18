targetScope = 'subscription'

@minLength(1)
@maxLength(64)
param environmentName string
@metadata({ azd: { type: 'location' } })
@minLength(1)
param location string
@metadata({ azd: { type: 'location' } })
@minLength(1)
param connectorNamespaceLocation string = 'westcentralus'
@metadata({ azd: { type: 'principalId' } })
param userPrincipalId string = deployer().objectId

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}
module connectorNamespace './connector-namespace.bicep' = {
  scope: rg
  name: '${abbrs.connectorNamespaces}${resourceToken}'
  params: {
    name: '${abbrs.connectorNamespaces}${resourceToken}'
    location: connectorNamespaceLocation
    tags: tags
    connectionName: '${abbrs.connectorNamespacesConnections}${resourceToken}'
    userPrincipalId: userPrincipalId
  }
}
output resourceGroupResourceId string = rg.id
output resourceGroupName string = rg.name
output functionAppName string = '${abbrs.webSitesFunctions}${resourceToken}'
output connectorNamespaceName string = connectorNamespace.outputs.name
output connectorNamespaceResourceId string = connectorNamespace.outputs.resourceId
output connectorNamespaceConnectionName string = connectorNamespace.outputs.connectionName
output CONNECTOR_NAMESPACE_LOCATION string = connectorNamespaceLocation

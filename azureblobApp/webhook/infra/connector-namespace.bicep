// Connector Namespace + Azure Blob connection using Entra ID (OAuth).
// Requires interactive consent during post-deploy to authenticate.

param name string
param location string
param tags object = {}
param connectionName string

resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
}

resource azureblobConnection 'Microsoft.Web/connectorGateways/connections@2026-05-01-preview' = {
  parent: connectorNamespace
  name: connectionName
  properties: {
    connectorName: 'azureblob'
    parameterValueSet: {
      name: 'tokenBasedAuth'
    }
  }
}

@description('The resource ID of the Connector Namespace.')
output resourceId string = connectorNamespace.id

@description('The name of the Connector Namespace.')
output name string = connectorNamespace.name

@description('The name of the Azure Blob connection on the namespace.')
output connectionName string = azureblobConnection.name

@description('Runtime URL for the Azure Blob connection.')
output azureblobConnectionRuntimeUrl string = azureblobConnection.properties.connectionRuntimeUrl

// The namespace's system-assigned identity authenticates to Azure Blob Storage.

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
      name: 'managedIdentityAuth'
      values: {}
    }
  }
}

resource namespaceAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = {
  parent: azureblobConnection
  name: 'namespace-mi'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: connectorNamespace.identity.principalId
        tenantId: tenant().tenantId
      }
    }
  }
}

@description('Object ID of the namespace identity used to access source blobs.')
output principalId string = connectorNamespace.identity.principalId

@description('The resource ID of the Connector Namespace.')
output resourceId string = connectorNamespace.id

@description('The name of the Connector Namespace.')
output name string = connectorNamespace.name

@description('The name of the Azure Blob connection on the namespace.')
output connectionName string = azureblobConnection.name

@description('Runtime URL for the Azure Blob connection.')
output azureblobConnectionRuntimeUrl string = azureblobConnection.properties.connectionRuntimeUrl

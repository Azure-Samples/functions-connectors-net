param name string
param location string
param tags object = {}
param connectionName string
@description('Optional. AAD object ID of a user (typically the deployer) to also grant access to the connection, so the same code can be debugged locally with `az login` credentials.')
param userPrincipalId string = ''
param tenantId string = tenant().tenantId

resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
}

resource sharepointConnection 'Microsoft.Web/connectorGateways/connections@2026-05-01-preview' = {
  parent: connectorNamespace
  name: connectionName
  properties: {
    connectorName: 'sharepointonline'
  }
}

// Deployer (dev) -> SharePoint connection (so local dev can use the same connection).
resource sharepointConnectionUserAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = if (!empty(userPrincipalId)) {
  parent: sharepointConnection
  name: 'dev-user'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: userPrincipalId
        tenantId: tenantId
      }
    }
  }
}

@description('The resource ID of the Connector Namespace.')
output resourceId string = connectorNamespace.id

@description('The name of the Connector Namespace.')
output name string = connectorNamespace.name

@description('The name of the SharePoint connection on the namespace.')
output connectionName string = sharepointConnection.name

@description('Runtime URL for the SharePoint connection.')
output sharepointConnectionRuntimeUrl string = sharepointConnection.properties.connectionRuntimeUrl

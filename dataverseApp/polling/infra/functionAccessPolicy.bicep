// Authorizes the user-assigned identity to receive and acknowledge Poll events.

param connectorNamespaceName string
param connectionName string
param tenantId string = tenant().tenantId

@description('Object (principal) ID of the function app user-assigned managed identity.')
param functionAppPrincipalId string

resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = {
  name: connectorNamespaceName
}

resource dataverseConnection 'Microsoft.Web/connectorGateways/connections@2026-05-01-preview' existing = {
  parent: connectorNamespace
  name: connectionName
}

resource dataverseConnectionFunctionAppAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = {
  parent: dataverseConnection
  name: 'functionapp-msi'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: functionAppPrincipalId
        tenantId: tenantId
      }
    }
  }
}

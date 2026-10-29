// Grants the function app's user-assigned managed identity access to the
// Dataverse (commondataservice) connection so it can call connector actions at
// runtime (e.g. the ListDataverseRows HTTP function). The action authenticates
// with DefaultAzureCredential + AZURE_CLIENT_ID, so it runs as the user-assigned
// identity — this ACL must target that same principal.

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

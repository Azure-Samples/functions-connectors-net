param name string
param location string
param tags object
param connectionName string
param userPrincipalId string
param connectorName string
param authenticationType string = ''

resource gateway 'Microsoft.Web/connectorGateways@2026-05-01-preview' = {
  name: name
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
}
resource connection 'Microsoft.Web/connectorGateways/connections@2026-05-01-preview' = {
  parent: gateway
  name: connectionName
  properties: union({
    connectorName: connectorName
  }, !empty(authenticationType) ? {
    parameterValueSet: { name: authenticationType, values: {} }
  } : {})
}
resource developerAccess 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = if (!empty(userPrincipalId)) {
  parent: connection
  name: 'developer'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: { objectId: userPrincipalId, tenantId: tenant().tenantId }
    }
  }
}
output name string = gateway.name
output resourceId string = gateway.id
output connectionName string = connection.name

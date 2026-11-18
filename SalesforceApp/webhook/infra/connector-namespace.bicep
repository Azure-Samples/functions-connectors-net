param name string
param location string
param tags object
param connectionName string

resource gateway 'Microsoft.Web/connectorGateways@2026-05-01-preview' = {
  name: name
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
}
resource connection 'Microsoft.Web/connectorGateways/connections@2026-05-01-preview' = {
  parent: gateway
  name: connectionName
  properties: { connectorName: 'salesforce' }
}
output name string = gateway.name
output connectionName string = connection.name

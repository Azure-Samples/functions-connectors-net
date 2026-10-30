param namespaceName string
param connectionName string
@minLength(1)
param triggers array

resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = {
  name: namespaceName
}

resource triggerConfigs 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' = [
  for trigger in triggers: {
    parent: connectorNamespace
    name: 'sharepoint-${toLower(trigger.functionName)}'
    properties: {
      connectionDetails: {
        connectionName: connectionName
        connectorName: 'sharepointonline'
      }
      deliveryMode: 'Poll'
      operationName: trigger.operationName
      parameters: trigger.parameters
      state: 'Enabled'
      type: 'NotSpecified'
      description: 'SharePoint Online ${trigger.functionName} with Poll delivery.'
    }
  }
]

// The extension accepts either a gateway path or a stable-DNS authority, without an operation or query.
var receiveUri = split(string(triggerConfigs[0].properties.pollingEndpoints.receiveUri), '?')[0]
var endpointBase = substring(receiveUri, 0, indexOf(toLower(receiveUri), '/triggerconfigs/'))

output pollingEndpoint string = endsWith(toLower(endpointBase), '/api')
  ? substring(endpointBase, 0, max(0, length(endpointBase) - 4))
  : endpointBase

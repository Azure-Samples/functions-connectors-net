param namespaceName string
param connectionName string
@minLength(1)
param triggers array

resource gateway 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = { name: namespaceName }
resource configs 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' = [
  for trigger in triggers: {
    parent: gateway
    name: 'salesforce-${toLower(trigger.functionName)}'
    properties: {
      connectionDetails: { connectionName: connectionName, connectorName: 'salesforce' }
      deliveryMode: 'Poll'
      operationName: trigger.operationName
      parameters: trigger.parameters
      state: 'Enabled'
      type: 'NotSpecified'
      description: 'Salesforce ${trigger.functionName} with Poll delivery.'
    }
  }
]

// Preserve the service authority/gateway path; the extension builds receive/acknowledge routes.
var receiveUri = split(string(configs[0].properties.pollingEndpoints.receiveUri), '?')[0]
var endpoint = substring(receiveUri, 0, indexOf(toLower(receiveUri), '/triggerconfigs/'))
output pollingEndpoint string = endsWith(toLower(endpoint), '/api')
  ? substring(endpoint, 0, max(0, length(endpoint) - 4))
  : endpoint

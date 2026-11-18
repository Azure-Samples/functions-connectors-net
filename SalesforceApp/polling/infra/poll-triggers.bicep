param namespaceName string
param connectionName string
param functionAppName string
param triggerPlan string

var plan = json(base64ToString(triggerPlan))
var connectorName = loadJsonContent('./scripts/polling-config.json').connectorName
var endpointConfigName = plan.?endpointConfigName ?? ''

resource gateway 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = { name: namespaceName }
resource configs 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' = [
  for trigger in plan.selected: {
    parent: gateway
    name: trigger.name
    properties: {
      connectionDetails: { connectionName: connectionName, connectorName: connectorName }
      deliveryMode: 'Poll'
      operationName: trigger.operationName
      parameters: trigger.parameters
      metadata: {
        destinationType: 'functionApp'
        functionAppName: functionAppName
        functionAppResourceGroup: resourceGroup().name
        functionAppSubscriptionId: subscription().subscriptionId
        functionName: trigger.functionName
      }
      state: 'Enabled'
      type: 'NotSpecified'
      description: 'Salesforce ${trigger.functionName} with Poll delivery.'
    }
  }
]

// Preserve the service authority/gateway path; the extension builds receive/acknowledge routes.
resource endpointConfig 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' existing = if (!empty(endpointConfigName)) {
  parent: gateway
  name: endpointConfigName
}
var receiveUri = empty(endpointConfigName) ? '' : split(string(endpointConfig!.properties.pollingEndpoints.receiveUri), '?')[0]
var pathIndex = indexOf(toLower(receiveUri), '/triggerconfigs/')
var endpoint = pathIndex < 0 ? '' : substring(receiveUri, 0, pathIndex)
output pollingEndpoint string = endsWith(toLower(endpoint), '/api')
  ? substring(endpoint, 0, max(0, length(endpoint) - 4))
  : endpoint

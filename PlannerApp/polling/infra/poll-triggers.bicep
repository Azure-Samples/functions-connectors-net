param namespaceName string
param connectionName string
param functionAppName string
param triggerPlan string

var plan = json(base64ToString(triggerPlan))
var connectorName = loadJsonContent('./scripts/polling-config.json').connectorName
var endpointConfigName = plan.?endpointConfigName ?? ''

resource namespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = { name: namespaceName }
resource configs 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' = [for trigger in plan.selected: {
  parent: namespace
  name: trigger.name
  properties: {
    connectionDetails: { connectionName: connectionName, connectorName: connectorName }
    deliveryMode: 'Poll'
    operationName: trigger.operationName
    parameters: trigger.parameters
    state: 'Enabled'
    type: 'NotSpecified'
    description: '${trigger.name} with Poll delivery.'
    metadata: {
      destinationType: 'functionApp'
      functionAppName: functionAppName
      functionAppResourceGroup: resourceGroup().name
      functionAppSubscriptionId: subscription().subscriptionId
      functionName: trigger.functionName
      recurrenceFrequency: 'Minute'
      recurrenceInterval: '6'
    }
  }
}]
resource endpointConfig 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' existing = if (!empty(endpointConfigName)) {
  parent: namespace
  name: endpointConfigName
}
var receiveUri = empty(endpointConfigName) ? '' : split(string(endpointConfig!.properties.pollingEndpoints.receiveUri), '?')[0]
var pathIndex = indexOf(toLower(receiveUri), '/triggerconfigs/')
var endpointBase = pathIndex < 0 ? '' : substring(receiveUri, 0, pathIndex)
output pollingEndpoint string = endsWith(toLower(endpointBase), '/api')
  ? substring(endpointBase, 0, max(0, length(endpointBase) - 4))
  : endpointBase

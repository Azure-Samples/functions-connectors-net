param namespaceName string
param connectionName string
param functionAppName string
@minLength(1)
param triggers array

resource namespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = { name: namespaceName }
resource configs 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' = [for trigger in triggers: {
  parent: namespace
  name: 'planner-${toLower(trigger.functionName)}'
  properties: {
    connectionDetails: { connectionName: connectionName, connectorName: 'planner' }
    deliveryMode: 'Poll'
    operationName: trigger.operationName
    parameters: trigger.parameters
    state: 'Enabled'
    type: 'NotSpecified'
    description: trigger.description
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
var receiveUri = split(string(configs[0].properties.pollingEndpoints.receiveUri), '?')[0]
var endpointBase = substring(receiveUri, 0, indexOf(toLower(receiveUri), '/triggerconfigs/'))
output pollingEndpoint string = endsWith(toLower(endpointBase), '/api')
  ? substring(endpointBase, 0, max(0, length(endpointBase) - 4))
  : endpointBase

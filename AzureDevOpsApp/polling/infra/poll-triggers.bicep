param namespaceName string
param connectionName string
param functionAppName string
@minLength(1)
param triggers array

resource gateway 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = { name: namespaceName }
resource configs 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' = [for trigger in triggers: {
  parent: gateway
  name: 'azuredevops-${toLower(trigger.functionName)}'
  properties: {
    connectionDetails: { connectionName: connectionName, connectorName: 'visualstudioteamservices' }
    operationName: trigger.operationName
    parameters: trigger.parameters
    metadata: {
      destinationType: 'functionApp'
      functionAppName: functionAppName
      functionAppResourceGroup: resourceGroup().name
      functionAppSubscriptionId: subscription().subscriptionId
      functionName: trigger.functionName
    }
    deliveryMode: 'Poll'
    state: 'Enabled'
    type: 'NotSpecified'
    description: 'Azure DevOps ${trigger.functionName} with Poll delivery.'
  }
}]
var receiveUri = split(string(configs[0].properties.pollingEndpoints.receiveUri), '?')[0]
var base = substring(receiveUri, 0, indexOf(toLower(receiveUri), '/triggerconfigs/'))
output pollingEndpoint string = endsWith(toLower(base), '/api') ? substring(base, 0, max(0, length(base) - 4)) : base

param namespaceName string
param connectionName string
@minLength(1)
param environmentUrl string
param tableName string = 'accounts'

var dataset = endsWith(environmentUrl, '/') ? substring(environmentUrl, 0, length(environmentUrl) - 1) : environmentUrl

var rowTriggers = [
  { functionName: 'OnDataverseRowChanged', operationName: 'GetOnNewItems_V2' }
  { functionName: 'OnDataverseRowModified', operationName: 'GetOnUpdatedItems_V2' }
  { functionName: 'OnDataverseRowDeleted', operationName: 'GetOnDeletedItems_V2' }
]

resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = {
  name: namespaceName
}

resource triggerConfigs 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' = [for trigger in rowTriggers: {
  parent: connectorNamespace
  name: 'dataverse-${toLower(trigger.functionName)}'
  properties: {
    connectionDetails: {
      connectionName: connectionName
      connectorName: 'commondataservice'
    }
    deliveryMode: 'Poll'
    operationName: trigger.operationName
    parameters: [
      { name: 'dataset', value: dataset }
      { name: 'table', value: tableName }
    ]
    state: 'Enabled'
    type: 'NotSpecified'
    description: 'Dataverse ${trigger.functionName} with Poll delivery.'
    metadata: {
      recurrenceFrequency: 'Minute'
      recurrenceInterval: '5'
    }
  }
}]

// Use the service-generated endpoint, not an assumed namespace hostname.
var receiveUri = split(string(triggerConfigs[0].properties.pollingEndpoints.receiveUri), '?')[0]
var endpointBase = substring(receiveUri, 0, indexOf(toLower(receiveUri), '/triggerconfigs/'))

output pollingEndpoint string = endsWith(toLower(endpointBase), '/api')
  ? substring(endpointBase, 0, max(0, length(endpointBase) - 4))
  : endpointBase

output triggerConfigSettings object = {
  OnDataverseRowChangedTriggerConfigName: triggerConfigs[0].name
  OnDataverseRowModifiedTriggerConfigName: triggerConfigs[1].name
  OnDataverseRowDeletedTriggerConfigName: triggerConfigs[2].name
}

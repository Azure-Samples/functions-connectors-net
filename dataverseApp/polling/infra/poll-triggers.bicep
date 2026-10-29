param namespaceName string
param connectionName string
@minLength(1)
param environmentUrl string
param tableName string = 'accounts'

var dataset = endsWith(environmentUrl, '/') ? substring(environmentUrl, 0, length(environmentUrl) - 1) : environmentUrl

resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = {
  name: namespaceName
}

resource triggerConfig 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' = {
  parent: connectorNamespace
  name: 'dataverse-ondataverserowchanged'
  properties: {
    connectionDetails: {
      connectionName: connectionName
      connectorName: 'commondataservice'
    }
    deliveryMode: 'Poll'
    operationName: 'GetOnNewItems_V2'
    parameters: [
      { name: 'dataset', value: dataset }
      { name: 'table', value: tableName }
    ]
    state: 'Enabled'
    type: 'NotSpecified'
    description: 'Dataverse new rows with Poll delivery.'
    metadata: {
      recurrenceFrequency: 'Minute'
      recurrenceInterval: '5'
    }
  }
}

// Use the service-generated endpoint, not an assumed namespace hostname.
var receiveUri = split(string(triggerConfig.properties.pollingEndpoints.receiveUri), '?')[0]
var endpointBase = substring(receiveUri, 0, indexOf(toLower(receiveUri), '/triggerconfigs/'))

output pollingEndpoint string = endsWith(toLower(endpointBase), '/api')
  ? substring(endpointBase, 0, max(0, length(endpointBase) - 4))
  : endpointBase

output triggerConfigSettings object = {
  OnDataverseRowChangedTriggerConfigName: triggerConfig.name
}

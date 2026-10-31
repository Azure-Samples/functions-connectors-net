param namespaceName string
param connectionName string
@minLength(1)
param environmentUrl string
param tableName string = 'account'
param enableActionTrigger bool = false
param eventCatalog string = ''
param eventCategory string = ''
param eventTable string = ''
param eventAction string = ''

var organization = endsWith(environmentUrl, '/') ? substring(environmentUrl, 0, length(environmentUrl) - 1) : environmentUrl

resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = {
  name: namespaceName
}

resource rowTrigger 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' = {
  parent: connectorNamespace
  name: 'dataverse-ondataverserowchanged'
  properties: {
    connectionDetails: { connectionName: connectionName, connectorName: 'commondataservice' }
    deliveryMode: 'Poll'
    operationName: 'SubscribeWebhookTrigger'
    parameters: [
      { name: 'organization', value: organization }
      { name: 'entityname', value: tableName }
      { name: 'message', value: '7' }
      { name: 'scope', value: '4' }
    ]
    state: 'Enabled'
    type: 'NotSpecified'
    description: 'Current Dataverse added, modified, or deleted operation with Poll delivery.'
  }
}

resource actionTrigger 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' = if (enableActionTrigger) {
  parent: connectorNamespace
  name: 'dataverse-ondataverseactionperformed'
  properties: {
    connectionDetails: { connectionName: connectionName, connectorName: 'commondataservice' }
    deliveryMode: 'Poll'
    operationName: 'BusinessEventsTrigger'
    parameters: [
      { name: 'organization', value: organization }
      { name: 'catalog', value: eventCatalog }
      { name: 'category', value: eventCategory }
      { name: 'entityname', value: eventTable }
      { name: 'sdkmessagename', value: eventAction }
    ]
    state: 'Enabled'
    type: 'NotSpecified'
    description: 'Current Dataverse action-performed operation with Poll delivery.'
  }
}

var receiveUri = split(string(rowTrigger.properties.pollingEndpoints.receiveUri), '?')[0]
var endpointBase = substring(receiveUri, 0, indexOf(toLower(receiveUri), '/triggerconfigs/'))

output pollingEndpoint string = endsWith(toLower(endpointBase), '/api')
  ? substring(endpointBase, 0, max(0, length(endpointBase) - 4))
  : endpointBase

output triggerConfigSettings object = {
  OnDataverseRowChangedTriggerConfigName: rowTrigger.name
  OnDataverseActionPerformedTriggerConfigName: 'dataverse-ondataverseactionperformed'
  'AzureWebJobs.OnDataverseActionPerformed.Disabled': string(!enableActionTrigger)
}

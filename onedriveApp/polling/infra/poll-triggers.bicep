param namespaceName string
param connectionName string
param folderId string

var triggers = [
  {
    functionName: 'OnNewFile'
    operationName: 'OnNewFilesV2'
  }
  {
    functionName: 'OnUpdatedFile'
    operationName: 'OnUpdatedFilesV2'
  }
]

resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = {
  name: namespaceName
}

resource triggerConfigs 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' = [
  for trigger in triggers: {
    parent: connectorNamespace
    name: 'onedrive-${toLower(trigger.functionName)}'
    properties: {
      connectionDetails: {
        connectionName: connectionName
        connectorName: 'onedriveforbusiness'
      }
      deliveryMode: 'Poll'
      operationName: trigger.operationName
      parameters: [
        { name: 'folderId', value: folderId }
      ]
      state: 'Enabled'
      type: 'NotSpecified'
      description: 'OneDrive ${trigger.functionName} with Poll delivery.'
    }
  }
]

// Preserve the service's host and optional gateway path; omit the receive operation and query.
var receiveUri = split(string(triggerConfigs[0].properties.pollingEndpoints.receiveUri), '?')[0]
var endpointBase = substring(receiveUri, 0, indexOf(toLower(receiveUri), '/triggerconfigs/'))

output pollingEndpoint string = endsWith(toLower(endpointBase), '/api')
  ? substring(endpointBase, 0, max(0, length(endpointBase) - 4))
  : endpointBase

output triggerConfigSettings object = toObject(
  triggers,
  trigger => '${trigger.functionName}TriggerConfigName',
  trigger => 'onedrive-${toLower(trigger.functionName)}'
)

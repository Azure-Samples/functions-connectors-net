param namespaceName string
param connectionName string
param teamsGroupId string
param teamsChannelId string

var channelParameters = [
  { name: 'groupId', value: teamsGroupId }
  { name: 'channelId', value: teamsChannelId }
]
var membershipParameters = [
  { name: 'groupId', value: teamsGroupId }
]
var triggers = [
  {
    functionName: 'OnNewChannelMessage'
    parameters: channelParameters
  }
  {
    functionName: 'OnNewChannelMessageMentioningMe'
    parameters: channelParameters
  }
  {
    functionName: 'OnGroupMembershipAdd'
    parameters: membershipParameters
  }
  {
    functionName: 'OnGroupMembershipRemoval'
    parameters: membershipParameters
  }
]

resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = {
  name: namespaceName
}

resource triggerConfigs 'Microsoft.Web/connectorGateways/triggerConfigs@2026-05-01-preview' = [
  for trigger in triggers: {
    parent: connectorNamespace
    name: 'teams-${toLower(trigger.functionName)}'
    properties: {
      connectionDetails: {
        connectionName: connectionName
        connectorName: 'teams'
      }
      deliveryMode: 'Poll'
      operationName: trigger.functionName
      parameters: trigger.parameters
      state: 'Enabled'
      type: 'NotSpecified'
      description: 'Teams ${trigger.functionName} with Poll delivery.'
    }
  }
]

// Keep the service-provided authority and optional gateway path.
var receiveUri = split(string(triggerConfigs[0].properties.pollingEndpoints.receiveUri), '?')[0]
var endpointBase = substring(receiveUri, 0, indexOf(toLower(receiveUri), '/triggerconfigs/'))

output pollingEndpoint string = endsWith(toLower(endpointBase), '/api')
  ? substring(endpointBase, 0, max(0, length(endpointBase) - 4))
  : endpointBase

output triggerConfigSettings object = toObject(
  triggers,
  trigger => '${trigger.functionName}TriggerConfigName',
  trigger => 'teams-${toLower(trigger.functionName)}'
)

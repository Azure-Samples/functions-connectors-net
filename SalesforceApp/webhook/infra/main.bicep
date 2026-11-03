targetScope = 'subscription'

@minLength(1)
@maxLength(64)
param environmentName string
@metadata({ azd: { type: 'location' } })
param location string
param connectorNamespaceLocation string = 'westcentralus'
@metadata({ azd: { type: 'principalId' } })
param userPrincipalId string = deployer().objectId
@description('Exact Salesforce object API name returned by GetTables, for example Account. Requires approved org/object access.')
@minLength(1)
param salesforceObject string
param salesforceFilter string = ''
param salesforceOrderBy string = ''
@description('Keep Id, CreatedDate and LastModifiedDate available for trigger tracking.')
param salesforceSelect string = 'Id,CreatedDate,LastModifiedDate'

var token = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var triggerParameters = concat(
  [{ name: 'table', value: salesforceObject }],
  empty(salesforceFilter) ? [] : [{ name: '$filter', value: salesforceFilter }],
  empty(salesforceOrderBy) ? [] : [{ name: '$orderby', value: salesforceOrderBy }],
  empty(salesforceSelect) ? [] : [{ name: '$select', value: salesforceSelect }]
)
var triggers = [for trigger in loadJsonContent('./triggers.json'): {
  functionName: trigger.functionName
  operationName: trigger.operationName
  parameters: triggerParameters
}]

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources './resources.bicep' = {
  name: 'resources'
  scope: rg
  params: { token: token, location: location, tags: tags }
}

module connector './connector-namespace.bicep' = {
  name: 'connector-namespace'
  scope: rg
  params: {
    name: 'cns-${token}'
    connectionName: 'cnsc-${token}'
    location: connectorNamespaceLocation
    tags: tags
  }
}

module app './function-app.bicep' = {
  name: 'function-app'
  scope: rg
  params: {
    token: token
    location: location
    tags: tags
    planId: resources.outputs.planId
    storageName: resources.outputs.storageName
    packageContainerUri: resources.outputs.packageContainerUri
    insightsConnectionString: resources.outputs.insightsConnectionString
  }
}

module access './function-access.bicep' = {
  name: 'post-app-access'
  scope: rg
  params: {
    functionAppPrincipalId: app.outputs.principalId
    userPrincipalId: userPrincipalId
    namespaceName: connector.outputs.name
    connectionName: connector.outputs.connectionName
    storageName: resources.outputs.storageName
    insightsName: resources.outputs.insightsName
  }
}

output resourceGroupName string = rg.name
output functionAppName string = app.outputs.name
output functionAppDefaultHostname string = app.outputs.hostname
output connectorNamespaceName string = connector.outputs.name
output connectorNamespaceConnectionName string = connector.outputs.connectionName
output triggerDefinitions array = triggers

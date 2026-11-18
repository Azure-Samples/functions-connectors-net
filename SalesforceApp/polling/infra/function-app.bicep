param environmentName string
param location string
param namespaceName string
param connectionName string
@minLength(1)
param pollingEndpoint string
param triggerSettings string
@allowed(['true', 'false'])
param functionAppExists string = 'false'
@metadata({ azd: { type: 'principalId' } })
param userPrincipalId string = deployer().objectId

var token = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var functionAppName = 'func-${token}'
var currentSettings = functionAppExists == 'true'
  ? list('${resourceId('Microsoft.Web/sites', functionAppName)}/config/appsettings', '2024-11-01').properties
  : {}

module resources './resources.bicep' = {
  name: 'resources'
  params: { token: token, location: location, tags: tags }
}
module app './site.bicep' = {
  name: 'function-app'
  params: {
    token: token
    location: location
    tags: tags
    planId: resources.outputs.planId
    storageName: resources.outputs.storageName
    packageContainerUri: resources.outputs.packageContainerUri
    insightsConnectionString: resources.outputs.insightsConnectionString
    existingAppSettings: currentSettings
    pollingSettings: union(json(base64ToString(triggerSettings)), {
      ConnectorNamespace__pollingEndpoint: pollingEndpoint
    })
  }
}
module access './function-access.bicep' = {
  name: 'post-app-access'
  params: {
    functionAppPrincipalId: app.outputs.principalId
    userPrincipalId: userPrincipalId
    namespaceName: namespaceName
    connectionName: connectionName
    storageName: resources.outputs.storageName
    insightsName: resources.outputs.insightsName
  }
}
output FUNCTION_APP_NAME string = app.outputs.name
output connectorPollingEndpoint string = pollingEndpoint

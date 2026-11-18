param environmentName string
param location string
@minLength(1)
param telemetryLocation string = location
param namespaceName string
param connectionName string
@minLength(1)
param pollingEndpoint string
param triggerSettings string
@allowed(['true', 'false'])
param functionAppExists string = 'false'
@metadata({ azd: { type: 'principalId' } })
param userPrincipalId string = deployer().objectId
@allowed(['User', 'ServicePrincipal', 'Group'])
param userPrincipalType string = 'User'
@allowed([0, 1])
@description('Reserved instances per selected Poll function. One is an explicit paid opt-in.')
param pollingReadyInstanceCount int = 0

var functionAppName = 'func-${uniqueString(resourceGroup().id)}'
var currentSettings = functionAppExists == 'true'
  ? list('${resourceId('Microsoft.Web/sites', functionAppName)}/config/appsettings', '2025-03-01').properties
  : {}

module app './app.bicep' = {
  name: 'azuredevops-polling'
  params: {
    location: location
    telemetryLocation: telemetryLocation
    namespaceName: namespaceName
    connectionName: connectionName
    pollingEndpoint: pollingEndpoint
    triggerSettings: json(base64ToString(triggerSettings))
    existingAppSettings: currentSettings
    environmentName: environmentName
    userPrincipalId: userPrincipalId
    userPrincipalType: userPrincipalType
    pollingReadyInstanceCount: pollingReadyInstanceCount
  }
}
output FUNCTION_APP_NAME string = app.outputs.functionAppName
output connectorPollingEndpoint string = pollingEndpoint

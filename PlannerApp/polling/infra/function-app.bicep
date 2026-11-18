@minLength(1)
@maxLength(64)
param environmentName string
@metadata({ azd: { type: 'location' } })
param location string
@metadata({ azd: { type: 'principalId' } })
param userPrincipalId string = deployer().objectId
param namespaceName string
param connectionName string
@minLength(1)
param pollingEndpoint string
param triggerSettings string
@allowed(['true', 'false'])
param functionAppExists string = 'false'

var token = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var containerName = 'app-package-${token}'
var developerStorageRoles = [for role in [
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
]: { roleDefinitionIdOrName: role, principalId: userPrincipalId, principalType: 'User' }]
var settings = json(base64ToString(triggerSettings))
var functionAppName = 'func-${token}'
var currentSettings = functionAppExists == 'true'
  ? list('${resourceId('Microsoft.Web/sites', functionAppName)}/config/appsettings', '2025-03-01').properties
  : {}
module logs 'br/public:avm/res/operational-insights/workspace:0.15.0' = {
  name: 'logs'
  params: { name: 'log-${token}', location: location, tags: tags, dataRetention: 30 }
}
module monitoring 'br/public:avm/res/insights/component:0.7.1' = {
  name: 'monitoring'
  params: {
    name: 'appi-${token}'
    location: location
    tags: tags
    workspaceResourceId: logs.outputs.resourceId
    disableLocalAuth: true
    roleAssignments: empty(userPrincipalId) ? [] : [{
      roleDefinitionIdOrName: '3913510d-42f4-4e42-8a64-420c390055eb'
      principalId: userPrincipalId
      principalType: 'User'
    }]
  }
}
module storage 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'storage'
  params: {
    name: 'st${token}'
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: { defaultAction: 'Allow' }
    minimumTlsVersion: 'TLS1_2'
    blobServices: { containers: [{ name: containerName }] }
    roleAssignments: empty(userPrincipalId) ? [] : developerStorageRoles
  }
}
module plan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'plan'
  params: { name: 'plan-${token}', location: location, tags: tags, skuName: 'FC1', reserved: true }
}
module app 'br/public:avm/res/web/site:0.22.0' = {
  name: 'app'
  params: {
    name: 'func-${token}'
    location: location
    tags: union(tags, { 'azd-service-name': 'function-app' })
    kind: 'functionapp,linux'
    serverFarmResourceId: plan.outputs.resourceId
    httpsOnly: true
    managedIdentities: { systemAssigned: true }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.outputs.primaryBlobEndpoint}${containerName}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 100
        alwaysReady: []
      }
      runtime: { name: 'dotnet-isolated', version: '10.0' }
    }
    siteConfig: { minTlsVersion: '1.2' }
    configs: [{
      name: 'appsettings'
      properties: union(currentSettings, settings, {
        AzureWebJobsStorage__credential: 'managedidentity'
        AzureWebJobsStorage__accountName: storage.outputs.name
        APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
        APPLICATIONINSIGHTS_CONNECTION_STRING: monitoring.outputs.connectionString
        ConnectorNamespace__credential: 'managedidentity'
        ConnectorNamespace__pollingEndpoint: pollingEndpoint
      })
    }]
  }
}
module rbac './function-access.bicep' = {
  name: 'function-rbac'
  params: {
    principalId: app.outputs.systemAssignedMIPrincipalId!
    storageName: storage.outputs.name
    monitoringName: monitoring.outputs.name
    namespaceName: namespaceName
    connectionName: connectionName
  }
}
output FUNCTION_APP_NAME string = app.outputs.name
output connectorPollingEndpoint string = pollingEndpoint

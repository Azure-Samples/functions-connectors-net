targetScope = 'subscription'

@minLength(1)
@maxLength(64)
param environmentName string
@metadata({ azd: { type: 'location' } })
param location string
param connectorNamespaceLocation string = 'westcentralus'
@metadata({ azd: { type: 'principalId' } })
param userPrincipalId string = deployer().objectId
@minLength(1)
param plannerGroupId string
@minLength(1)
param plannerPlanId string
@description('Assignment events apply to all tasks assigned to the connection user, not only the selected plan.')
param plannerEnableAssignedToMe bool = false

var token = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var containerName = 'app-package-${token}'
var developerStorageRoles = [for role in [
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
]: { roleDefinitionIdOrName: role, principalId: userPrincipalId, principalType: 'User' }]
var definitions = [for trigger in loadJsonContent('./triggers.json'): {
  functionName: trigger.functionName
  operationName: trigger.operationName
  description: trigger.description
  enabled: trigger.planScoped || plannerEnableAssignedToMe
  parameters: trigger.planScoped ? [
    { name: 'groupId', value: plannerGroupId }
    { name: 'id', value: plannerPlanId }
  ] : []
}]
var settings = toObject(definitions, trigger => 'AzureWebJobs.${trigger.functionName}.Disabled', trigger => string(!trigger.enabled))
resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}
module logs 'br/public:avm/res/operational-insights/workspace:0.15.0' = {
  scope: rg
  name: 'logs'
  params: { name: 'log-${token}', location: location, tags: tags, dataRetention: 30 }
}
module monitoring 'br/public:avm/res/insights/component:0.7.1' = {
  scope: rg
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
  scope: rg
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
  scope: rg
  name: 'plan'
  params: { name: 'plan-${token}', location: location, tags: tags, skuName: 'FC1', reserved: true }
}
module namespace './connector-namespace.bicep' = {
  scope: rg
  name: 'namespace'
  params: {
    name: 'cns-${token}'
    location: connectorNamespaceLocation
    tags: tags
    connectionName: 'cnsc-${token}'
    userPrincipalId: userPrincipalId
  }
}
module app 'br/public:avm/res/web/site:0.22.0' = {
  scope: rg
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
      scaleAndConcurrency: { instanceMemoryMB: 2048, maximumInstanceCount: 100 }
      runtime: { name: 'dotnet-isolated', version: '10.0' }
    }
    siteConfig: { minTlsVersion: '1.2' }
    configs: [{
      name: 'appsettings'
      properties: union({
        AzureWebJobsStorage__credential: 'managedidentity'
        AzureWebJobsStorage__accountName: storage.outputs.name
        APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
        APPLICATIONINSIGHTS_CONNECTION_STRING: monitoring.outputs.connectionString
        ConnectorNamespace__credential: 'managedidentity'
      }, settings)
    }]
  }
}
module rbac './function-access.bicep' = {
  scope: rg
  name: 'function-rbac'
  params: {
    principalId: app.outputs.systemAssignedMIPrincipalId!
    storageName: storage.outputs.name
    monitoringName: monitoring.outputs.name
  }
}
output resourceGroupName string = rg.name
output functionAppName string = app.outputs.name
output functionAppDefaultHostname string = app.outputs.defaultHostname
output connectorNamespaceName string = namespace.outputs.name
output connectorNamespaceConnectionName string = namespace.outputs.connectionName
output triggerConfigSettings object = settings
output triggerDefinitions array = definitions

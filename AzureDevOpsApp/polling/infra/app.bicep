param location string
param telemetryLocation string
param namespaceName string
param connectionName string
param pollingEndpoint string
param triggerSettings object
@secure()
param existingAppSettings object = {}
param environmentName string
param userPrincipalId string
param userPrincipalType string
param pollingReadyInstanceCount int

var token = uniqueString(resourceGroup().id)
var functionAppName = 'func-${token}'
var tags = { 'azd-env-name': environmentName }
var readyTriggers = filter(loadJsonContent('./scripts/polling-config.json').triggers,
  trigger => triggerSettings['AzureWebJobs.${trigger.functionName}.Disabled'] == 'false' && pollingReadyInstanceCount > 0)

resource storage 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: 'st${token}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-06-01' = {
  parent: storage
  name: 'default'
}
resource packages 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-06-01' = {
  parent: blobService
  name: 'app-packages'
}
resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: 'log-${token}'
  location: telemetryLocation
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}
resource monitoring 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${token}'
  location: telemetryLocation
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
  }
}
resource plan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: 'plan-${token}'
  location: location
  kind: 'linux'
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}
resource app 'Microsoft.Web/sites@2025-03-01' = {
  name: functionAppName
  location: location
  tags: union(tags, { 'azd-service-name': 'function-app' })
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${packages.name}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      runtime: { name: 'dotnet-isolated', version: '10.0' }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
        alwaysReady: [for trigger in readyTriggers: {
          name: 'function:${trigger.functionName}'
          instanceCount: pollingReadyInstanceCount
        }]
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      appSettings: map(items(union(existingAppSettings, triggerSettings, {
        AzureWebJobsStorage__credential: 'managedidentity'
        AzureWebJobsStorage__blobServiceUri: storage.properties.primaryEndpoints.blob
        AzureWebJobsStorage__queueServiceUri: storage.properties.primaryEndpoints.queue
        AzureWebJobsStorage__tableServiceUri: storage.properties.primaryEndpoints.table
        APPLICATIONINSIGHTS_CONNECTION_STRING: monitoring.properties.ConnectionString
        APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
        ConnectorNamespace__credential: 'managedidentity'
        ConnectorNamespace__pollingEndpoint: pollingEndpoint
      })), setting => { name: setting.key, value: string(setting.value) })
    }
  }
}
module access './function-access.bicep' = {
  name: 'post-app-access'
  params: {
    functionAppPrincipalId: app.identity!.principalId!
    userPrincipalId: userPrincipalId
    userPrincipalType: userPrincipalType
    storageName: storage.name
    monitoringName: monitoring.name
    namespaceName: namespaceName
    connectionName: connectionName
  }
}
output functionAppName string = app.name

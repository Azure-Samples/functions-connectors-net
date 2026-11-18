@minLength(1)
@maxLength(64)
@description('Environment name. Use a unique name per deployment.')
param environmentName string

@metadata({
  azd: {
    type: 'location'
  }
})
@description('Location for all resources except the Connector Namespace.')
param location string

@description('Region for Application Insights and Log Analytics; may differ from the Function App region.')
param telemetryLocation string = 'eastus2'

@metadata({
  azd: {
    type: 'principalId'
  }
})
@description('Developer identity granted access to the connection and storage for local development.')
param userPrincipalId string = deployer().objectId

@minLength(1)
param pollingEndpoint string
param namespaceName string
param connectionName string
param triggerSettings string
@allowed(['true', 'false'])
param functionAppExists string = 'false'

metadata name = 'Azure Functions Teams Polling Connector Trigger (.NET)'
metadata description = 'Connector Namespace Poll delivery using managed identity, without a callback URL.'

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var functionAppName = 'func-${resourceToken}'
var deploymentStorageContainerName = 'app-package-${resourceToken}'
var storageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

var currentSettings = functionAppExists == 'true'
  ? list('${resourceId('Microsoft.Web/sites', functionAppName)}/config/appsettings', '2025-03-01').properties
  : {}

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.15.0' = {
  name: 'loganalytics'
  params: {
    name: 'log-${resourceToken}-${telemetryLocation}'
    location: telemetryLocation
    tags: tags
    dataRetention: 30
  }
}

module monitoring 'br/public:avm/res/insights/component:0.7.1' = {
  name: 'appinsights'
  params: {
    name: 'appi-${resourceToken}'
    location: telemetryLocation
    tags: tags
    workspaceResourceId: logAnalytics.outputs.resourceId
    disableLocalAuth: true
    roleAssignments: [
      {
        roleDefinitionIdOrName: monitoringMetricsPublisherRoleId
        principalId: userPrincipalId
        principalType: 'User'
      }
    ]
  }
}

module storageAccount 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'storage'
  params: {
    name: 'st${resourceToken}'
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
    minimumTlsVersion: 'TLS1_2'
    blobServices: {
      containers: [{ name: deploymentStorageContainerName }]
    }
    roleAssignments: [
      {
        roleDefinitionIdOrName: storageBlobDataOwner
        principalId: userPrincipalId
        principalType: 'User'
      }
      {
        roleDefinitionIdOrName: storageQueueDataContributor
        principalId: userPrincipalId
        principalType: 'User'
      }
      {
        roleDefinitionIdOrName: storageTableDataContributor
        principalId: userPrincipalId
        principalType: 'User'
      }
    ]
  }
}

module functionAppPlan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'function-plan'
  params: {
    name: 'plan-${resourceToken}'
    location: location
    tags: tags
    skuName: 'FC1'
    reserved: true
  }
}

var allAppSettings = union(
  currentSettings,
  json(base64ToString(triggerSettings)),
  {
    AzureWebJobsStorage__credential: 'managedidentity'
    AzureWebJobsStorage__accountName: storageAccount.outputs.name
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
    APPLICATIONINSIGHTS_CONNECTION_STRING: monitoring.outputs.connectionString
    ConnectorNamespace__credential: 'managedidentity'
    ConnectorNamespace__pollingEndpoint: pollingEndpoint
  }
)

module functionApp 'br/public:avm/res/web/site:0.22.0' = {
  name: 'function-app'
  params: {
    name: functionAppName
    location: location
    tags: union(tags, { 'azd-service-name': 'function-app' })
    kind: 'functionapp,linux'
    serverFarmResourceId: functionAppPlan.outputs.resourceId
    httpsOnly: true
    managedIdentities: {
      systemAssigned: true
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.outputs.primaryBlobEndpoint}${deploymentStorageContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 100
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
    // Override the module default without emitting AlwaysOn for Flex Consumption.
    siteConfig: {
      minTlsVersion: '1.2'
      functionsRuntimeScaleMonitoringEnabled: false
    }
    configs: [
      {
        name: 'appsettings'
        properties: allAppSettings
      }
    ]
  }
}

// Assign app permissions after creation so storage and namespace provisioning do not depend on the app.
module functionAppAccess './function-access.bicep' = {
  name: 'function-app-access'
  params: {
    principalId: functionApp.outputs.systemAssignedMIPrincipalId!
    storageAccountName: storageAccount.outputs.name
    appInsightsName: monitoring.outputs.name
    connectorNamespaceName: namespaceName
    connectionName: connectionName
  }
}

output FUNCTION_APP_NAME string = functionApp.outputs.name
output connectorPollingEndpoint string = pollingEndpoint

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@metadata({
  azd: {
    type: 'location'
  }
})
@minLength(1)
@description('Region for the Function App, storage account, and resource group.')
param location string

@metadata({
  azd: {
    type: 'location'
  }
})
@minLength(1)
@description('Region for Application Insights and Log Analytics.')
param telemetryLocation string

param namespaceName string
param connectionName string
@minLength(1)
param pollingEndpoint string
param triggerSettings string
@allowed(['true', 'false'])
param functionAppExists string = 'false'

metadata name = 'Azure Functions Microsoft Dataverse Poll Delivery (.NET)'
metadata description = 'Dataverse events with interactive trigger configuration and Poll delivery.'

@description('Id of the user identity to be used for testing and debugging. Granted access to the Dataverse connection so the same code can be debugged locally with `az login`.')
@metadata({
  azd: {
    type: 'principalId'
  }
})
param userPrincipalId string = deployer().objectId

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

var functionAppName = '${abbrs.webSitesFunctions}${resourceToken}'
var functionAppPlanName = '${abbrs.webServerFarms}${resourceToken}'
var storageAccountName = '${abbrs.storageStorageAccounts}${resourceToken}'
var logAnalyticsName = '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
var appInsightsName = '${abbrs.insightsComponents}${resourceToken}'

var deploymentStorageContainerName = 'app-package-${take(functionAppName, 32)}-${take(toLower(uniqueString(functionAppName, environmentName)), 7)}'
var storageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

var currentSettings = functionAppExists == 'true'
  ? list('${resourceId('Microsoft.Web/sites', functionAppName)}/config/appsettings', '2025-03-01').properties
  : {}

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.15.0' = {
  name: '${uniqueString(deployment().name, location)}-loganalytics'
  params: {
    name: logAnalyticsName
    location: telemetryLocation
    tags: tags
    dataRetention: 30
  }
}

module monitoring 'br/public:avm/res/insights/component:0.7.1' = {
  name: '${uniqueString(deployment().name, location)}-appinsights'
  params: {
    name: appInsightsName
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
  name: storageAccountName
  params: {
    name: storageAccountName
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
  name: functionAppPlanName
  params: {
    name: functionAppPlanName
    location: location
    tags: tags
    skuName: 'FC1'
    reserved: true
  }
}

var allAppSettings = union(currentSettings, json(base64ToString(triggerSettings)), {
  AzureWebJobsStorage__credential: 'managedidentity'
  AzureWebJobsStorage__accountName: storageAccount.outputs.name
  APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
  APPLICATIONINSIGHTS_CONNECTION_STRING: monitoring.outputs.connectionString
  ConnectorNamespace__credential: 'managedidentity'
  ConnectorNamespace__pollingEndpoint: pollingEndpoint
})

module functionApp 'br/public:avm/res/web/site:0.22.0' = {
  name: functionAppName
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
        alwaysReady: []
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
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

// Assign app roles after its identity exists, avoiding storage/app dependency cycles.
module functionAppRbac './function-access.bicep' = {
  name: '${functionAppName}-rbac'
  params: {
    storageAccountName: storageAccount.outputs.name
    appInsightsName: monitoring.outputs.name
    functionAppPrincipalId: functionApp.outputs.systemAssignedMIPrincipalId!
  }
}

// Grant the function app's system-assigned identity access to the Dataverse connection.
module functionAccessPolicy './connection-access.bicep' = {
  name: '${namespaceName}-func-policy'
  params: {
    connectorNamespaceName: namespaceName
    connectionName: connectionName
    functionAppPrincipalId: functionApp.outputs.systemAssignedMIPrincipalId!
  }
}

@description('The name of the created Function App.')
output FUNCTION_APP_NAME string = functionApp.outputs.name

@description('The default hostname of the created Function App.')
output functionAppDefaultHostname string = functionApp.outputs.defaultHostname

output connectorPollingEndpoint string = pollingEndpoint

targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Environment name. Use a different name from the webhook sample.')
param environmentName string

@metadata({
  azd: {
    type: 'location'
  }
})
param location string

param connectorNamespaceLocation string = 'westcentralus'

@description('Application Insights region. Empty uses location; select a supported region when location does not offer Application Insights.')
param applicationInsightsLocation string = ''

@metadata({
  azd: {
    type: 'principalId'
  }
})
@description('Developer identity for local polling, source blob access, and host storage.')
param userPrincipalId string = deployer().objectId

param monitoredContainerName string = 'connector-input'

metadata name = 'Azure Functions Azure Blob Polling Connector Trigger (.NET)'
metadata description = 'Connector Namespace Poll delivery using managed identity, without a callback URL.'

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var deploymentStorageContainerName = 'app-package-${resourceToken}'
var storageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.15.0' = {
  name: 'loganalytics'
  scope: rg
  params: {
    name: 'log-${resourceToken}'
    location: location
    tags: tags
    dataRetention: 30
  }
}

module funcUserAssignedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.0' = {
  name: 'function-identity'
  scope: rg
  params: {
    name: 'id-${resourceToken}'
    location: location
    tags: tags
  }
}

module monitoring 'br/public:avm/res/insights/component:0.7.1' = {
  name: 'appinsights'
  scope: rg
  params: {
    name: 'appi-${resourceToken}'
    location: empty(applicationInsightsLocation) ? location : applicationInsightsLocation
    tags: tags
    workspaceResourceId: logAnalytics.outputs.resourceId
    disableLocalAuth: true
    roleAssignments: [
      {
        roleDefinitionIdOrName: monitoringMetricsPublisherRoleId
        principalId: funcUserAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
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
  scope: rg
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
        principalId: funcUserAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: storageQueueDataContributor
        principalId: funcUserAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: storageTableDataContributor
        principalId: funcUserAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
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

module monitoredStorageAccount 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'source-storage'
  scope: rg
  params: {
    name: 'stmon${resourceToken}'
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
      containers: [{ name: monitoredContainerName }]
    }
    roleAssignments: [
      {
        roleDefinitionIdOrName: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
        principalId: userPrincipalId
        principalType: 'User'
      }
    ]
  }
}

module functionAppPlan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'function-plan'
  scope: rg
  params: {
    name: 'plan-${resourceToken}'
    location: location
    tags: tags
    skuName: 'FC1'
    reserved: true
  }
}

module connectorNamespace './connectorNamespace.bicep' = {
  name: 'connector-namespace'
  scope: rg
  params: {
    name: 'cns-${resourceToken}'
    location: connectorNamespaceLocation
    tags: tags
    connectionName: 'cnsc-${resourceToken}'
    functionAppPrincipalId: funcUserAssignedIdentity.outputs.principalId
    userPrincipalId: userPrincipalId
  }
}

module pollTriggers './poll-triggers.bicep' = {
  name: 'poll-triggers'
  scope: rg
  params: {
    namespaceName: connectorNamespace.outputs.name
    connectionName: connectorNamespace.outputs.connectionName
    monitoredStorageAccountName: monitoredStorageAccount.outputs.name
    monitoredContainerName: monitoredContainerName
  }
}

var allAppSettings = {
  AzureWebJobsStorage__credential: 'managedidentity'
  AzureWebJobsStorage__clientId: funcUserAssignedIdentity.outputs.clientId
  AzureWebJobsStorage__accountName: storageAccount.outputs.name
  APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${funcUserAssignedIdentity.outputs.clientId};Authorization=AAD'
  APPLICATIONINSIGHTS_CONNECTION_STRING: monitoring.outputs.connectionString
  AZURE_CLIENT_ID: funcUserAssignedIdentity.outputs.clientId
  ConnectorNamespace__credential: 'managedidentity'
  ConnectorNamespace__clientId: funcUserAssignedIdentity.outputs.clientId
  ConnectorNamespace__pollingEndpoint: pollTriggers.outputs.pollingEndpoint
  OnUpdatedFileTriggerConfigName: pollTriggers.outputs.triggerConfigName
}

module functionApp 'br/public:avm/res/web/site:0.22.0' = {
  name: 'function-app'
  scope: rg
  params: {
    name: 'func-${resourceToken}'
    location: location
    tags: union(tags, { 'azd-service-name': 'function-app' })
    kind: 'functionapp,linux'
    serverFarmResourceId: functionAppPlan.outputs.resourceId
    httpsOnly: true
    managedIdentities: {
      userAssignedResourceIds: [funcUserAssignedIdentity.outputs.resourceId]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.outputs.primaryBlobEndpoint}${deploymentStorageContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: funcUserAssignedIdentity.outputs.resourceId
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
    siteConfig: {
      minTlsVersion: '1.2'
    }
    configs: [
      {
        name: 'appsettings'
        properties: allAppSettings
      }
    ]
  }
}

output resourceGroupName string = rg.name
output functionAppName string = functionApp.outputs.name
output connectorNamespaceName string = connectorNamespace.outputs.name
output connectorNamespaceConnectionName string = connectorNamespace.outputs.connectionName
output connectorPollingEndpoint string = pollTriggers.outputs.pollingEndpoint
output onUpdatedFileTriggerConfigName string = pollTriggers.outputs.triggerConfigName
output monitoredStorageAccountName string = monitoredStorageAccount.outputs.name
output monitoredContainerName string = monitoredContainerName

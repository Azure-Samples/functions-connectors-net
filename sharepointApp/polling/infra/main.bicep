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
@description('Location for all resources except the Connector Namespace.')
param location string

@description('Region for the Connector Namespace.')
param connectorNamespaceLocation string = 'westcentralus'

@metadata({
  azd: {
    type: 'principalId'
  }
})
@description('Developer identity granted access to the connection and storage for local development.')
param userPrincipalId string = deployer().objectId

@description('SharePoint site URL to monitor (e.g., https://contoso.sharepoint.com/sites/mysite).')
param sharepointSiteUrl string
@description('SharePoint document library name or GUID accepted by the connector.')
param sharepointLibraryName string = 'Documents'
@description('Optional folder path accepted by the connector. Leave empty to monitor the whole library.')
param sharepointFolderPath string = ''

@description('List name or GUID for item/form triggers. Empty uses the document library as a list.')
param sharepointListName string = ''
@description('Enable deletion triggers only when the connection user is a site collection administrator.')
param sharepointEnableDeletionTriggers bool = false
@description('Enable classification only after applying a licensed Microsoft Syntex model to the library.')
param sharepointEnableSyntexTrigger bool = false
@description('Existing form identifier. Empty disables the form-submitted preview trigger.')
param sharepointFormId string = ''
@description('Connector runSchedule value. Empty disables the recurring-digest preview trigger.')
@allowed(['', '*', '0', '1', '2', '3', '4', '5', '6'])
param sharepointDigestSchedule string = ''

metadata name = 'Azure Functions SharePoint Online Polling Connector Trigger (.NET)'
metadata description = 'Connector Namespace Poll delivery using managed identity, without a callback URL.'

var enabledGroups = {
  standard: true
  deletion: sharepointEnableDeletionTriggers
  syntex: sharepointEnableSyntexTrigger
  form: !empty(sharepointFormId)
  digest: !empty(sharepointDigestSchedule)
}
var triggerDefinitions = [for trigger in loadJsonContent('./triggers.json'): {
  functionName: trigger.functionName
  operationName: trigger.operationName
  description: trigger.description
  enabled: enabledGroups[trigger.group]
  parameters: concat([
    { name: 'dataset', value: sharepointSiteUrl }
    {
      name: 'table'
      value: trigger.target == 'list' && !empty(sharepointListName) ? sharepointListName : sharepointLibraryName
    }
  ], trigger.folder && !empty(sharepointFolderPath) ? [
    { name: 'folderPath', value: sharepointFolderPath }
  ] : [], trigger.group == 'form' ? [
    { name: 'form', value: sharepointFormId }
  ] : [], trigger.group == 'digest' ? [
    { name: 'update', value: true }
    { name: 'add', value: true }
    { name: 'runSchedule', value: sharepointDigestSchedule }
  ] : [])
}]
var enabledTriggers = filter(triggerDefinitions, trigger => trigger.enabled)
var triggerConfigSettings = union(
  toObject(triggerDefinitions, trigger => '${trigger.functionName}TriggerConfigName', trigger => 'sharepoint-${toLower(trigger.functionName)}'),
  toObject(triggerDefinitions, trigger => 'AzureWebJobs.${trigger.functionName}.Disabled', trigger => string(!trigger.enabled))
)

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var functionAppName = 'func-${resourceToken}'
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
    location: location
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
    triggers: enabledTriggers
  }
}

var allAppSettings = union(
  {
    AzureWebJobsStorage__credential: 'managedidentity'
    AzureWebJobsStorage__clientId: funcUserAssignedIdentity.outputs.clientId
    AzureWebJobsStorage__accountName: storageAccount.outputs.name
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${funcUserAssignedIdentity.outputs.clientId};Authorization=AAD'
    APPLICATIONINSIGHTS_CONNECTION_STRING: monitoring.outputs.connectionString
    AZURE_CLIENT_ID: funcUserAssignedIdentity.outputs.clientId
    ConnectorNamespace__credential: 'managedidentity'
    ConnectorNamespace__clientId: funcUserAssignedIdentity.outputs.clientId
    ConnectorNamespace__pollingEndpoint: pollTriggers.outputs.pollingEndpoint
  },
  triggerConfigSettings
)

module functionApp 'br/public:avm/res/web/site:0.22.0' = {
  name: 'function-app'
  scope: rg
  params: {
    name: functionAppName
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
        alwaysReady: [for trigger in enabledTriggers: {
          name: 'function:${trigger.functionName}'
          instanceCount: 1
        }]
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
    // Override the module default without emitting AlwaysOn for Flex Consumption.
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
output triggerConfigSettings object = triggerConfigSettings
output triggerDefinitions array = triggerDefinitions

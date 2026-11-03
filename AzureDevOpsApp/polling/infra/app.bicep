param location string
param telemetryLocation string
param connectorNamespaceLocation string
param environmentName string
param userPrincipalId string
param userPrincipalType string
param organization string
param project string
param repository string
param enableBuildTrigger bool
param enableTfvcTrigger bool
param team string
param assignedTo string
param workItemType string
param workItemTriggerSelection string
param pollingReadyInstanceCount int

var token = uniqueString(resourceGroup().id)
var functionAppName = 'func-${token}'
var tags = { 'azd-env-name': environmentName }
var groups = {
  work: true
  git: !empty(repository)
  build: enableBuildTrigger
  tfvc: enableTfvcTrigger
  assignment: !empty(team) && !empty(assignedTo)
}
var definitions = [
  { functionName: 'OnBuildCompleted', operationName: 'OnBuildCompleted', group: 'build' }
  { functionName: 'OnGitPullClosed', operationName: 'OnGitPullClosed', group: 'git' }
  { functionName: 'OnGitPullCreated', operationName: 'OnGitPullCreated', group: 'git' }
  { functionName: 'OnGitPush', operationName: 'OnGitPush', group: 'git' }
  { functionName: 'OnTfvcCheckIn', operationName: 'OnTfvcCheckIn', group: 'tfvc' }
  { functionName: 'OnWorkItemCreated', operationName: 'OnWorkItemCreatedV2', group: 'work' }
  { functionName: 'OnWorkItemUpdated', operationName: 'OnWorkItemUpdatedV2', group: 'work' }
  { functionName: 'OnWorkItemClosed', operationName: 'OnWorkItemClosedV2', group: 'work' }
  { functionName: 'OnWorkItemAssigned', operationName: 'OnWorkItemAssignedV2', group: 'assignment' }
]
var triggers = [for trigger in definitions: {
  functionName: trigger.functionName
  operationName: trigger.operationName
  enabled: groups[trigger.group] && (trigger.group != 'work' || workItemTriggerSelection == 'All' || trigger.functionName == 'OnWorkItemCreated')
  parameters: concat([
    { name: 'account', value: organization }
    { name: 'project', value: project }
  ], trigger.group == 'git' ? [{ name: 'repository', value: repository }] : [],
  trigger.group == 'assignment' ? [
    { name: 'team', value: team }
    { name: 'wiql__System_AssignedTo', value: assignedTo }
  ] : [], (trigger.group == 'work' || trigger.group == 'assignment') && !empty(workItemType)
    ? [{ name: 'wiql__System_WorkItemType', value: workItemType }] : [])
}]
var readyTriggers = filter(triggers, t => t.enabled && pollingReadyInstanceCount > 0)
var triggerSettings = union(
  toObject(triggers, t => '${t.functionName}TriggerConfigName', t => 'azuredevops-${toLower(t.functionName)}'),
  toObject(triggers, t => 'AzureWebJobs.${t.functionName}.Disabled', t => string(!t.enabled))
)

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
resource gateway 'Microsoft.Web/connectorGateways@2026-05-01-preview' = {
  name: 'cns-${token}'
  location: connectorNamespaceLocation
  tags: tags
  identity: { type: 'SystemAssigned' }
}
resource connection 'Microsoft.Web/connectorGateways/connections@2026-05-01-preview' = {
  parent: gateway
  name: 'cnsc-${token}'
  properties: { connectorName: 'visualstudioteamservices' }
}
resource developerAccess 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = if (!empty(userPrincipalId)) {
  parent: connection
  name: 'dev-user'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: { objectId: userPrincipalId, tenantId: tenant().tenantId }
    }
  }
}
module pollTriggers './poll-triggers.bicep' = {
  name: 'poll-triggers'
  params: {
    namespaceName: gateway.name
    connectionName: connection.name
    functionAppName: functionAppName
    triggers: filter(triggers, t => t.enabled)
  }
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
      appSettings: concat(map(items(triggerSettings), setting => { name: setting.key, value: setting.value }), [
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: storage.properties.primaryEndpoints.blob }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: storage.properties.primaryEndpoints.queue }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: storage.properties.primaryEndpoints.table }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: monitoring.properties.ConnectionString }
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD' }
        { name: 'ConnectorNamespace__credential', value: 'managedidentity' }
        { name: 'ConnectorNamespace__pollingEndpoint', value: pollTriggers.outputs.pollingEndpoint }
      ])
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
    namespaceName: gateway.name
    connectionName: connection.name
  }
}
output functionAppName string = app.name
output connectorNamespaceName string = gateway.name
output connectionName string = connection.name
output pollingEndpoint string = pollTriggers.outputs.pollingEndpoint
output triggerSettings object = triggerSettings
output triggerDefinitions array = triggers

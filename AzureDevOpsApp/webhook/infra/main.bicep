targetScope = 'subscription'

@minLength(1)
@maxLength(64)
param environmentName string
@metadata({ azd: { type: 'location' } })
param location string
@minLength(1)
@description('Region for Application Insights and Log Analytics. Defaults to the app region.')
param telemetryLocation string = location
param connectorNamespaceLocation string = 'westcentralus'
@metadata({ azd: { type: 'principalId' } })
@description('Existing developer/deployment principal object ID. Empty omits its grants.')
param userPrincipalId string = deployer().objectId
@allowed(['User', 'ServicePrincipal', 'Group'])
@description('Actual directory type of userPrincipalId. azd supplies its authenticated principal type.')
param userPrincipalType string
@minLength(1)
@description('Organization name, not a URL.')
param organization string
@minLength(1)
@description('Existing Azure DevOps project name.')
param project string
@description('Existing Git repository name. Empty disables all Git triggers.')
param repository string = ''
@description('Enable only for a project with existing build definitions.')
param enableBuildTrigger bool = false
@description('Enable only for an existing TFVC project.')
param enableTfvcTrigger bool = false
@description('Existing team name, required with assignedTo to enable assignment.')
param team string = ''
@description('Existing team member name accepted by wiql__System_AssignedTo.')
param assignedTo string = ''
@description('Optional work-item type filter.')
param workItemType string = ''
@allowed(['All', 'CreatedOnly'])
@description('Select create/update/close work-item triggers, or creation only. Other opt-ins are unchanged.')
param workItemTriggerSelection string = 'All'

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: { 'azd-env-name': environmentName }
}
module app './app.bicep' = {
  name: 'azuredevops-webhook'
  scope: rg
  params: {
    location: location
    telemetryLocation: telemetryLocation
    connectorNamespaceLocation: connectorNamespaceLocation
    environmentName: environmentName
    userPrincipalId: userPrincipalId
    userPrincipalType: userPrincipalType
    organization: organization
    project: project
    repository: repository
    enableBuildTrigger: enableBuildTrigger
    enableTfvcTrigger: enableTfvcTrigger
    team: team
    assignedTo: assignedTo
    workItemType: workItemType
    workItemTriggerSelection: workItemTriggerSelection
  }
}
output resourceGroupName string = rg.name
output functionAppName string = app.outputs.functionAppName
output functionAppDefaultHostname string = app.outputs.functionAppDefaultHostname
output connectorNamespaceName string = app.outputs.connectorNamespaceName
output connectorNamespaceConnectionName string = app.outputs.connectionName
output triggerConfigSettings object = app.outputs.triggerSettings
output triggerDefinitions array = app.outputs.triggerDefinitions

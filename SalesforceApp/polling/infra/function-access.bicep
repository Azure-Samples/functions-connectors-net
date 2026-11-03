@description('System-assigned principal returned by the newly provisioned Function App.')
@minLength(36)
@maxLength(36)
param functionAppPrincipalId string
param userPrincipalId string
param namespaceName string
param connectionName string
param storageName string
param insightsName string

resource gateway 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = { name: namespaceName }
resource connection 'Microsoft.Web/connectorGateways/connections@2026-05-01-preview' existing = {
  parent: gateway
  name: connectionName
}
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: storageName }
resource insights 'Microsoft.Insights/components@2020-02-02' existing = { name: insightsName }
var principals = concat(
  [{ id: functionAppPrincipalId, type: 'ServicePrincipal', policy: 'functionapp-msi' }],
  empty(userPrincipalId) ? [] : [{ id: userPrincipalId, type: 'User', policy: 'developer' }]
)
var storageRoles = [
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
]
var storageAssignments = flatten(map(principals, principal =>
  map(storageRoles, role => { principal: principal, role: role })))
resource connectionAccess 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = [
  for principal in principals: {
    parent: connection
    name: principal.policy
    properties: {
      principal: {
        type: 'ActiveDirectory'
        identity: { objectId: principal.id, tenantId: tenant().tenantId }
      }
    }
  }
]
resource storageAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for assignment in storageAssignments: {
    name: guid(storage.id, assignment.principal.id, assignment.role)
    scope: storage
    properties: {
      principalId: assignment.principal.id
      principalType: assignment.principal.type
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', assignment.role)
    }
  }
]
resource monitoringAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principal in principals: {
    name: guid(insights.id, principal.id, '3913510d-42f4-4e42-8a64-420c390055eb')
    scope: insights
    properties: {
      principalId: principal.id
      principalType: principal.type
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    }
  }
]

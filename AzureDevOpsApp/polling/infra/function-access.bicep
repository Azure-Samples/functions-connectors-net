@minLength(1)
param functionAppPrincipalId string
param userPrincipalId string
@allowed(['User', 'ServicePrincipal', 'Group'])
param userPrincipalType string
param storageName string
param monitoringName string
param namespaceName string
param connectionName string

resource storage 'Microsoft.Storage/storageAccounts@2025-06-01' existing = { name: storageName }
resource monitoring 'Microsoft.Insights/components@2020-02-02' existing = { name: monitoringName }
resource gateway 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = { name: namespaceName }
resource connection 'Microsoft.Web/connectorGateways/connections@2026-05-01-preview' existing = {
  parent: gateway
  name: connectionName
}
var principals = concat([{ principalId: functionAppPrincipalId, principalType: 'ServicePrincipal' }], !empty(userPrincipalId) ? [{ principalId: userPrincipalId, principalType: userPrincipalType }] : [])
var storageRoles = [
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
]
var assignments = flatten(map(principals, principal => map(storageRoles, role => {
  principal: principal
  role: role
})))
resource storageAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for assignment in assignments: {
  scope: storage
  name: guid(storage.id, assignment.principal.principalId, assignment.role)
  properties: union(assignment.principal, {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', assignment.role)
  })
}]
resource monitoringAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principal in principals: {
  scope: monitoring
  name: guid(monitoring.id, principal.principalId, '3913510d-42f4-4e42-8a64-420c390055eb')
  properties: union(principal, {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  })
}]
resource functionAccess 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = {
  parent: connection
  name: 'functionapp-msi'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: { objectId: functionAppPrincipalId, tenantId: tenant().tenantId }
    }
  }
}

@minLength(1)
param principalId string
param storageName string
param monitoringName string

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = { name: storageName }
resource monitoring 'Microsoft.Insights/components@2020-02-02' existing = { name: monitoringName }
var storageRoles = [
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
]
resource storageAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in storageRoles: {
  scope: storage
  name: guid(storage.id, principalId, role)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
  }
}]
resource monitoringAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: monitoring
  name: guid(monitoring.id, principalId, '3913510d-42f4-4e42-8a64-420c390055eb')
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
}

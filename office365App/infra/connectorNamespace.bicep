param name string
param location string
param tags object = {}
param connectionName string
@description('Resource ID of the user-assigned managed identity to attach to the Connector Namespace. This is the identity the trigger uses to mint tokens when calling the function app callback URL.')
param triggerIdentityResourceId string
@description('Object (principal) ID of the same user-assigned managed identity, granted access to the office365 connection.')
param triggerIdentityPrincipalId string
@description('Object (principal) ID of the function app user-assigned MI. Granted access to the office365 connection so it can call the connector at runtime.')
param functionAppPrincipalId string
@description('Optional. AAD object ID of a user (typically the deployer) to also grant access to the connection, so the same code can be debugged locally with `az login` credentials.')
param userPrincipalId string = ''
param tenantId string = tenant().tenantId

@description('When false, reference the namespace as existing instead of creating/updating it. Required workaround for the Connector Namespace RP rejecting identity in update PUTs ("ManagedIdentityInvalid: user assigned identities can not be changed"), even when the body is byte-for-byte identical to current state. Set to false on the second+ provision by running: azd env set CREATE_CONNECTOR_NAMESPACE false')
param createConnectorNamespace bool = true

resource newConnectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' = if (createConnectorNamespace) {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${triggerIdentityResourceId}': {}
    }
  }
}

resource existingConnectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' existing = if (!createConnectorNamespace) {
  name: name
}

// Use a fully-qualified child name so we don't need a conditional `parent:`
// (Bicep doesn't allow conditional parent references).
resource office365Connection 'Microsoft.Web/connectorGateways/connections@2026-05-01-preview' = {
  name: '${name}/${connectionName}'
  properties: {
    connectorName: 'office365'
  }
  dependsOn: createConnectorNamespace ? [ newConnectorNamespace ] : [ existingConnectorNamespace ]
}

// Function App MI -> Office 365 connection (used by the trigger callback path).
resource office365ConnectionFunctionAppAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = {
  parent: office365Connection
  name: 'functionapp-msi'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: functionAppPrincipalId
        tenantId: tenantId
      }
    }
  }
}

// Trigger UAMI -> Office 365 connection. The connector namespace runtime impersonates
// this identity when reading from the mailbox on behalf of the trigger config.
resource office365ConnectionTriggerIdentityAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = {
  parent: office365Connection
  name: 'trigger-msi'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: triggerIdentityPrincipalId
        tenantId: tenantId
      }
    }
  }
}

// Deployer (dev) -> Office 365 connection (so local dev can use the same connection).
resource office365ConnectionUserAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = if (!empty(userPrincipalId)) {
  parent: office365Connection
  name: 'dev-user'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: userPrincipalId
        tenantId: tenantId
      }
    }
  }
}

@description('The resource ID of the Connector Namespace.')
output resourceId string = createConnectorNamespace ? newConnectorNamespace.id : existingConnectorNamespace.id

@description('The name of the Connector Namespace.')
output name string = name

@description('The name of the Office 365 connection on the namespace.')
output connectionName string = connectionName

@description('Runtime URL for the Office 365 connection.')
output office365ConnectionRuntimeUrl string = office365Connection.properties.connectionRuntimeUrl


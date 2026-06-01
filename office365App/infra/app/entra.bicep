extension microsoftGraphV1

@description('Unique name (across tenant) for the Entra app registration. Used for idempotency.')
param appUniqueName string

@description('Display name for the Entra app registration.')
param appDisplayName string

@description('Optional. References application or service contact information from a Service or Asset Management database. Required by some tenant policies (see https://aka.ms/service-management-reference-error).')
param serviceManagementReference string = ''

@description('Sign-in audience. AzureADMyOrg keeps the app single-tenant.')
param signInAudience string = 'AzureADMyOrg'

@description('Principal (object) ID of the user-assigned managed identity that will federate against this app. The FIC trusts this object ID; built-in authentication on the function app reads the corresponding clientId from an app setting to mint client assertions.')
param managedIdentityPrincipalId string

@description('Function App hostname (e.g. myfunc.azurewebsites.net). Used to build the built-in authentication redirect URI.')
param functionAppHostname string

@description('Tags object (key/value) passed in via azd.')
param tags object = {}

var tagStrings = !empty(tags) ? map(items(tags), tag => '${tag.key}:${tag.value}') : []

var identifierUri = 'api://${appUniqueName}-${uniqueString(subscription().id, resourceGroup().id, appUniqueName)}'
var redirectUri = 'https://${functionAppHostname}/.auth/login/aad/callback'

resource appRegistration 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: appUniqueName
  displayName: appDisplayName
  serviceManagementReference: !empty(serviceManagementReference) ? serviceManagementReference : null
  signInAudience: signInAudience
  identifierUris: [identifierUri]
  tags: tagStrings
  api: {
    requestedAccessTokenVersion: 2
  }
  web: {
    redirectUris: [redirectUri]
    implicitGrantSettings: {
      enableAccessTokenIssuance: false
      enableIdTokenIssuance: false
    }
  }
}

resource appServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: appRegistration.appId
  tags: tagStrings
}

// Federated identity credential lets the function app's user-assigned MI mint
// client assertions for this Entra app, so built-in authentication never needs a client secret.
resource federatedIdentityCredential 'Microsoft.Graph/applications/federatedIdentityCredentials@v1.0' = {
  name: '${appRegistration.uniqueName}/function-app-managed-identity'
  audiences: [
    'api://AzureADTokenExchange'
  ]
  issuer: '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
  subject: managedIdentityPrincipalId
  description: 'Federated identity credential for Function App user-assigned MI (built-in authentication client assertion)'
}

@description('App (client) ID of the Entra app registration.')
output applicationId string = appRegistration.appId

@description('Identifier URI of the Entra app registration (use as token audience).')
output identifierUri string = identifierUri

@description('Object ID of the app service principal.')
output servicePrincipalObjectId string = appServicePrincipal.id

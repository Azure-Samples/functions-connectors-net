targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@metadata({
  azd: {
    type: 'location'
  }
})
@description('Location for all resources except the Connector Namespace (which is pinned to westcentralus while in preview).')
param location string

metadata name = 'Azure Functions M365 Email Secured (MI + built-in authentication)'
metadata description = 'Hello-world Connector Namespace trigger sample where the namespace authenticates to the function app via system-assigned MI + built-in authentication (no function key).'

@description('Id of the user identity to be used for testing and debugging. Granted access to the office365 connection so the same code can be debugged locally with `az login`.')
@metadata({
  azd: {
    type: 'principalId'
  }
})
param userPrincipalId string = deployer().objectId

@description('Name of the Azure Function that handles the Office 365 connector trigger.')
param office365FunctionName string = 'OnNewEmail'

@description('Optional. Service Management Reference (e.g. a service tree GUID) attached to the Entra app registration. Required by some tenant policies — see https://aka.ms/service-management-reference-error.')
param serviceManagementReference string = ''

@description('When false, the Connector Namespace is referenced as existing and not re-PUT. Workaround for the RP rejecting identity in update PUTs after creation. Set this to false (via `azd env set CREATE_CONNECTOR_NAMESPACE false`) after the first successful provision to make `azd up` idempotent.')
param createConnectorNamespace bool = true

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

var functionAppName = '${abbrs.webSitesFunctions}${resourceToken}'
var functionAppPlanName = '${abbrs.webServerFarms}${resourceToken}'
var functionAppIdentityName = '${abbrs.managedIdentityUserAssignedIdentities}${resourceToken}'
var triggerIdentityName = '${abbrs.managedIdentityUserAssignedIdentities}trigger-${resourceToken}'
var resourceGroupName = '${abbrs.resourcesResourceGroups}${environmentName}'
var storageAccountName = '${abbrs.storageStorageAccounts}${resourceToken}'
var logAnalyticsName = '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
var appInsightsName = '${abbrs.insightsComponents}${resourceToken}'
var connectorNamespaceName = '${abbrs.connectorNamespaces}${resourceToken}'
var connectorNamespaceConnectionName = '${abbrs.connectorNamespacesConnections}${resourceToken}'
var entraAppUniqueName = 'fn-${resourceToken}'

var deploymentStorageContainerName = 'app-package-${take(functionAppName, 32)}-${take(toLower(uniqueString(functionAppName, environmentName)), 7)}'
var storageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.15.0' = {
  name: '${uniqueString(deployment().name, location)}-loganalytics'
  scope: rg
  params: {
    name: logAnalyticsName
    location: location
    tags: tags
    dataRetention: 30
  }
}

module funcUserAssignedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.0' = {
  name: 'funcUserAssignedIdentity'
  scope: rg
  params: {
    location: location
    tags: tags
    name: functionAppIdentityName
  }
}

// Dedicated identity attached to the Connector Namespace. The trigger config
// references this UAMI by resource ID; the namespace runtime uses it to mint
// AAD tokens when calling the function app callback URL.
module triggerUserAssignedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.0' = {
  name: 'triggerUserAssignedIdentity'
  scope: rg
  params: {
    location: location
    tags: tags
    name: triggerIdentityName
  }
}

module monitoring 'br/public:avm/res/insights/component:0.7.1' = {
  name: '${uniqueString(deployment().name, location)}-appinsights'
  scope: rg
  params: {
    name: appInsightsName
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
  scope: rg
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
  scope: rg
  name: functionAppPlanName
  params: {
    name: functionAppPlanName
    location: location
    tags: tags
    skuName: 'FC1'
    reserved: true
  }
}

// Connector Namespace + office365 connection. A dedicated user-assigned MI is
// attached so the trigger can mint AAD tokens; built-in authentication on the function app
// validates those tokens and gates everything else out.
//
// NOTE: The Connector Namespace RP rejects `identity` in update PUTs after creation
// ("ManagedIdentityInvalid: user assigned identities can not be changed") even when
// the body is identical to current state. After the first successful provision, run:
//   azd env set CREATE_CONNECTOR_NAMESPACE false
// so subsequent `azd up`/`azd provision` skips the namespace PUT and only manages
// children (connection + access policies).
module connectorNamespace './connectorNamespace.bicep' = {
  scope: rg
  name: connectorNamespaceName
  params: {
    name: connectorNamespaceName
    location: 'westcentralus' // Connector Namespace preview region.
    tags: tags
    connectionName: connectorNamespaceConnectionName
    triggerIdentityResourceId: triggerUserAssignedIdentity.outputs.resourceId
    triggerIdentityPrincipalId: triggerUserAssignedIdentity.outputs.principalId
    functionAppPrincipalId: funcUserAssignedIdentity.outputs.principalId
    userPrincipalId: userPrincipalId
    createConnectorNamespace: createConnectorNamespace
  }
}

// Entra app registration that built-in authentication validates incoming tokens against.
// The function MI federates against this app so built-in auth needs no client secret.
module entraApp './app/entra.bicep' = {
  scope: rg
  name: 'entraApp'
  params: {
    appUniqueName: entraAppUniqueName
    appDisplayName: 'M365 Email Secured Function (${functionAppName})'
    serviceManagementReference: serviceManagementReference
    managedIdentityPrincipalId: funcUserAssignedIdentity.outputs.principalId
    functionAppHostname: '${functionAppName}.azurewebsites.net'
    tags: tags
  }
}

var allAppSettings = {
  AzureWebJobsStorage__credential: 'managedidentity'
  AzureWebJobsStorage__clientId: funcUserAssignedIdentity.outputs.clientId
  AzureWebJobsStorage__accountName: storageAccount.outputs.name
  APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${funcUserAssignedIdentity.outputs.clientId};Authorization=AAD'
  APPLICATIONINSIGHTS_CONNECTION_STRING: monitoring.outputs.connectionString
  AZURE_CLIENT_ID: funcUserAssignedIdentity.outputs.clientId
  OFFICE365_CONNECTION_RUNTIME_URL: connectorNamespace.outputs.office365ConnectionRuntimeUrl
  // Magic value: tells built-in authentication to use the named user-assigned MI to mint
  // a federated client assertion against the Entra app, in place of a client secret.
  OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID: funcUserAssignedIdentity.outputs.clientId
}

module functionApp 'br/public:avm/res/web/site:0.22.0' = {
  scope: rg
  name: functionAppName
  params: {
    name: functionAppName
    location: location
    tags: union(tags, { 'azd-service-name': 'function-app' })
    kind: 'functionapp,linux'
    serverFarmResourceId: functionAppPlan.outputs.resourceId
    httpsOnly: true
    managedIdentities: {
      userAssignedResourceIds: [
        '${funcUserAssignedIdentity.outputs.resourceId}'
      ]
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
      alwaysOn: false
    }
    configs: [
      {
        name: 'appsettings'
        properties: allAppSettings
      }
      {
        // Built-in authentication: every incoming request (including the connector callback)
        // must carry a valid Entra ID token whose audience matches our app and
        // whose caller object ID is the Connector Namespace's system-assigned MI.
        name: 'authsettingsV2'
        properties: {
          globalValidation: {
            requireAuthentication: true
            unauthenticatedClientAction: 'Return401'
            redirectToProvider: 'azureactivedirectory'
          }
          httpSettings: {
            requireHttps: true
            routes: {
              apiPrefix: '/.auth'
            }
            forwardProxy: {
              convention: 'NoProxy'
            }
          }
          identityProviders: {
            azureActiveDirectory: {
              enabled: true
              registration: {
                openIdIssuer: '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
                clientId: entraApp.outputs.applicationId
                // FIC instead of a client secret -- built-in authentication reads the
                // user-assigned MI from the named app setting and uses it to
                // mint client assertions for the Entra app.
                clientSecretSettingName: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'
              }
              validation: {
                jwtClaimChecks: {}
                allowedAudiences: [
                  entraApp.outputs.applicationId
                  entraApp.outputs.identifierUri
                ]
                defaultAuthorizationPolicy: {
                  allowedPrincipals: {
                    // Only the Connector Namespace's trigger UAMI is allowed in.
                    // Tokens are matched by oid (the UAMI's principalId).
                    identities: [
                      triggerUserAssignedIdentity.outputs.principalId
                    ]
                  }
                }
              }
              isAutoProvisioned: false
            }
          }
          login: {
            tokenStore: {
              enabled: false
            }
            preserveUrlFragmentsForLogins: false
          }
          platform: {
            enabled: true
            runtimeVersion: '~1'
          }
        }
      }
    ]
  }
}

@description('The resource ID of the created Resource Group.')
output resourceGroupResourceId string = rg.id

@description('The name of the created Resource Group.')
output resourceGroupName string = rg.name

@description('The name of the created Function App.')
output functionAppName string = functionApp.outputs.name

@description('The default hostname of the created Function App.')
output functionAppDefaultHostname string = functionApp.outputs.defaultHostname

@description('The name of the created Connector Namespace.')
output connectorNamespaceName string = connectorNamespace.outputs.name

@description('The name of the created Office 365 connection on the Connector Namespace.')
output connectorNamespaceConnectionName string = connectorNamespace.outputs.connectionName

@description('The name of the function that handles the Office 365 connector trigger.')
output office365FunctionName string = office365FunctionName

@description('App (client) ID of the Entra app registration built-in authentication validates against. Connector Namespace requests tokens for this audience.')
output entraAppClientId string = entraApp.outputs.applicationId

@description('Identifier URI of the Entra app registration (alternative audience value).')
output entraAppIdentifierUri string = entraApp.outputs.identifierUri

@description('Resource ID of the user-assigned MI attached to the Connector Namespace (referenced by the trigger config notificationDetails.authentication.identity).')
output triggerIdentityResourceId string = triggerUserAssignedIdentity.outputs.resourceId

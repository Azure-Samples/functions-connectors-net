param token string
param location string
param tags object
param planId string
param storageName string
param packageContainerUri string
param insightsConnectionString string
param pollingSettings object = {}

resource app 'Microsoft.Web/sites@2024-11-01' = {
  name: 'func-${token}'
  location: location
  tags: union(tags, { 'azd-service-name': 'function-app' })
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: planId
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: packageContainerUri
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      runtime: { name: 'dotnet-isolated', version: '10.0' }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 100
        alwaysReady: []
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      appSettings: [for setting in items(union({
        AzureWebJobsStorage__accountName: storageName
        APPLICATIONINSIGHTS_CONNECTION_STRING: insightsConnectionString
        APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
        ConnectorNamespace__credential: 'managedidentity'
      }, pollingSettings)): {
        name: setting.key
        value: setting.value
      }]
    }
  }
}

output name string = app.name
output hostname string = app.properties.defaultHostName
output principalId string = app.identity.principalId

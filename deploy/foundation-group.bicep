targetScope = 'subscription'

param resourceGroupName string
param location string
param installationId string
param workloadName string

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    'inventory-sync-installation': installationId
    'inventory-sync-workload': workloadName
  }
}

output resourceGroupId string = resourceGroup.id

// ---------------------------------------------------------------------------
// dynatrace-oneagent.bicep — Dynatrace OneAgent VM extension.
//
// Applied as a separate module after the VM module finishes, so the OneAgent
// installer never races the PostgreSQL setup extension for the package lock.
//
// The Dynatrace extension reads the token from *public* settings (that is how
// the publisher designed it; see docs/DYNATRACE-SETUP.md). Terraform therefore
// mints a dedicated token scoped to InstallerDownload only — it cannot read or
// write any monitoring data.
// ---------------------------------------------------------------------------

@description('Name of an existing Linux VM in this resource group.')
param vmName string

param location string
param tags object

@description('Dynatrace environment ID, e.g. abc12345 (the first label of the environment host name).')
param environmentId string

@description('Classic environment API base, e.g. https://abc12345.live.dynatrace.com/api. Empty lets the extension derive it from environmentId.')
param apiUrl string = ''

@description('InstallerDownload-only PaaS token.')
@secure()
param paasToken string

@description('Dynatrace host group. Scopes problems and metric events to this lab.')
param hostGroup string

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: vmName
}

resource oneAgent 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'oneAgentLinux'
  location: location
  tags: tags
  properties: {
    publisher: 'dynatrace.ruxit'
    type: 'oneAgentLinux'
    typeHandlerVersion: '2.300'
    autoUpgradeMinorVersion: true
    settings: union({
      tenantId: environmentId
      token: paasToken
      hostGroup: hostGroup
      enableLogAnalytics: 'yes'
    }, empty(apiUrl) ? {} : {
      server: apiUrl
    })
  }
}

output extensionName string = oneAgent.name

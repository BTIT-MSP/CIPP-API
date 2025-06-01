function Get-ConnectWiseToken {
    [CmdletBinding()]
    param (
        $Configuration
    )
    if (![string]::IsNullOrEmpty($Configuration.CompanyId) -and ![string]::IsNullOrEmpty($Configuration.PublicKey)) {
        $PrivateKey = Get-ExtensionAPIKey -Extension 'ConnectWise'
        
        # Create authorization header
        $Combined = "$($Configuration.CompanyId)+$($Configuration.PublicKey):$PrivateKey"
        $Encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Combined))
        
        return @{
            Authorization = "Basic $Encoded"
            clientId = $env:WEBSITE_DEPLOYMENT_ID
        }
    } else {
        throw 'No ConnectWise configuration found'
    }
}
function Get-ConnectWiseMapping {
    [CmdletBinding()]
    param (
        $CIPPMapping
    )
    #Get available mappings
    $Mappings = [pscustomobject]@{}

    # Migrate legacy mappings
    $Filter = "PartitionKey eq 'Mapping'"
    $MigrateRows = Get-CIPPAzDataTableEntity @CIPPMapping -Filter $Filter | ForEach-Object {
        [PSCustomObject]@{
            PartitionKey    = 'ConnectWiseMapping'
            RowKey          = $_.RowKey
            IntegrationId   = $_.ConnectWise
            IntegrationName = $_.ConnectWiseName
        }
        Remove-AzDataTableEntity -Force @CIPPMapping -Entity $_ | Out-Null
    }
    if (($MigrateRows | Measure-Object).Count -gt 0) {
        Add-CIPPAzDataTableEntity @CIPPMapping -Entity $MigrateRows -Force
    }

    $ExtensionMappings = Get-ExtensionMapping -Extension 'ConnectWise'

    $Tenants = Get-Tenants -IncludeErrors

    $Mappings = foreach ($Mapping in $ExtensionMappings) {
        $Tenant = $Tenants | Where-Object { $_.RowKey -eq $Mapping.RowKey }
        if ($Tenant) {
            [PSCustomObject]@{
                TenantId        = $Tenant.customerId
                Tenant          = $Tenant.displayName
                TenantDomain    = $Tenant.defaultDomainName
                IntegrationId   = $Mapping.IntegrationId
                IntegrationName = $Mapping.IntegrationName
            }
        }
    }
    $Table = Get-CIPPTable -TableName Extensionsconfig
    try {
        $Configuration = ((Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json -ea stop).ConnectWise

        $Headers = Get-ConnectWiseToken -configuration $Configuration
        $i = 1
        $RawConnectWiseCompanies = do {
            $Result = Invoke-RestMethod -Uri "$($Configuration.ServerURL)/v4_6_release/apis/3.0/company/companies?page=$i&pageSize=1000" -ContentType 'application/json' -Method GET -Headers $Headers
            $Result
            $i++
            # ConnectWise uses different pagination - check if we got less than page size
        } while ($Result.Count -eq 1000)
    } catch {
        $Message = if ($_.ErrorDetails.Message) {
            Get-NormalizedError -Message $_.ErrorDetails.Message
        } else {
            $_.Exception.message
        }

        Write-LogMessage -Message "Could not get ConnectWise Companies, error: $Message " -Level Error -tenant 'CIPP' -API 'ConnectWiseMapping'
        $RawConnectWiseCompanies = @(@{name = "Could not get ConnectWise Companies, error: $Message"; id = '-1' })
    }
    $ConnectWiseCompanies = $RawConnectWiseCompanies | ForEach-Object {
        [PSCustomObject]@{
            name  = $_.name
            value = "$($_.id)"
        }
    }
    $MappingObj = [PSCustomObject]@{
        Companies = @($ConnectWiseCompanies)
        Mappings  = @($Mappings)
    }

    return $MappingObj

}
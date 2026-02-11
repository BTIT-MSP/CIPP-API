function Invoke-AddAPDevice {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.Autopilot.ReadWrite
    .DESCRIPTION
        Adds Autopilot devices to a tenant via Partner Center API
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    $TenantFilter = (Get-Tenants | Where-Object { $_.defaultDomainName -eq $Request.Body.TenantFilter.value }).customerId
    $GroupName = if ($Request.Body.Groupname) { $Request.Body.Groupname } else { (New-Guid).GUID }
    Write-Host $GroupName

    $rawDevices = $Request.Body.autopilotData
    $Devices = ConvertTo-Json @($rawDevices)
    $Result = try {
        $CurrentStatus = (New-GraphGetRequest -uri "https://api.partnercenter.microsoft.com/v1/customers/$TenantFilter/DeviceBatches" -scope 'https://api.partnercenter.microsoft.com/user_impersonation')
        if ($GroupName -in $CurrentStatus.items.id) {
            Write-Host 'Gonna do an update!'
            $Body = $Request.Body.autopilotData | ForEach-Object {
                $Device = $_
                [pscustomobject]@{
                    deviceBatchId       = $GroupName
                    hardwareHash        = $Device.hardwareHash
                    serialNumber        = $Device.SerialNumber
                    productKey          = $Device.productKey
                    oemManufacturerName = $Device.oemManufacturerName
                    modelName           = $Device.modelName
                }
            }
            $Body = ConvertTo-Json -Depth 10 -Compress -InputObject @($Body)
            Write-Host $Body
            $GraphRequest = (New-GraphPOSTRequest -returnHeaders $true -uri "https://api.partnercenter.microsoft.com/v1/customers/$TenantFilter/deviceBatches/$GroupName/devices" -body $Body -scope 'https://api.partnercenter.microsoft.com/user_impersonation')
        } else {
            $Body = '{"batchId":"' + $($GroupName) + '","devices":' + $Devices + '}'
            $GraphRequest = (New-GraphPOSTRequest -returnHeaders $true -uri "https://api.partnercenter.microsoft.com/v1/customers/$TenantFilter/DeviceBatches" -body $Body -scope 'https://api.partnercenter.microsoft.com/user_impersonation')
        }
        $Amount = 0
        do {
            Write-Host "Checking status of import job for $GroupName"
            $Amount++
            Start-Sleep 1
            $NewStatus = New-GraphGetRequest -uri "https://api.partnercenter.microsoft.com/v1/$($GraphRequest.Location)" -scope 'https://api.partnercenter.microsoft.com/user_impersonation'
        } until ($NewStatus.status -eq 'finished' -or $Amount -eq 4)
        if ($NewStatus.status -ne 'finished') { throw 'Could not retrieve status of import - This job might still be running. Check the autopilot device list in 10 minutes for the latest status.' }
        Write-LogMessage -headers $Request.Headers -API $APIName -tenant $($Request.body.TenantFilter.value) -message "Created Autopilot devices group. Group ID is $GroupName" -Sev 'Info'

        # Send alert notification for successful Autopilot device addition
        try {
            $TenantInfo = Get-Tenants -TenantFilter $Request.body.TenantFilter.value | Select-Object -First 1
            $ProcessedDevices = @($NewStatus.devicesStatus)
            
            if ($ProcessedDevices.Count -gt 0) {
                # Extract username from headers (same logic as Write-LogMessage)
                if ($Request.Headers.'x-ms-client-principal-idp' -eq 'azureStaticWebApps' -or !$Request.Headers.'x-ms-client-principal-idp') {
                    $User = $Request.Headers.'x-ms-client-principal'
                    $Username = ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($User)) | ConvertFrom-Json).userDetails
                } elseif ($Request.Headers.'x-ms-client-principal-idp' -eq 'aad') {
                    $Table = Get-CIPPTable -TableName 'ApiClients'
                    $Client = Get-CIPPAzDataTableEntity @Table -Filter "RowKey eq '$($Request.Headers.'x-ms-client-principal-name')'"
                    $Username = $Client.AppName ?? 'CIPP-API'
                } else {
                    $Username = 'Unknown User'
                }

                # Prepare alert data
                $AlertData = @{
                    TenantDisplayName = $TenantInfo.displayName
                    TenantId = $TenantInfo.customerId
                    Username = $Username
                    Devices = $ProcessedDevices | ForEach-Object {
                        @{
                            serialNumber = $_.serialNumber ?? 'Unknown'
                            hardwareHash = if ($_.hardwareHash) { $_.hardwareHash -replace '^(.{20}).*(.{20})$', '$1...$2' } else { 'Unknown' }  # Truncate for security
                            deviceName = $_.deviceName ?? 'Unknown'
                            model = $_.model ?? 'Unknown'
                            manufacturer = $_.manufacturer ?? 'Unknown'
                            status = if ($_.status) { $_.status } else { 'Processed' }
                        }
                    }
                }

                # Create alert template
                $HTMLContent = New-CIPPAlertTemplate -Data $AlertData -Format 'html' -InputObject 'autopilot' -CIPPURL $env:CIPPURL

                # Send email alert directly to support@baytechnologies.tech
                try {
                    $Recipients = @([pscustomobject]@{EmailAddress = @{Address = 'support@baytechnologies.tech' } })
                    $PowerShellBody = [PSCustomObject]@{
                        message         = @{
                            subject      = $HTMLContent.title
                            body         = @{
                                contentType = 'HTML'
                                content     = $HTMLContent.htmlcontent
                            }
                            toRecipients = @($Recipients)
                        }
                        saveToSentItems = 'true'
                    }

                    $JSONBody = ConvertTo-Json -Compress -Depth 10 -InputObject $PowerShellBody
                    $null = New-GraphPostRequest -uri 'https://graph.microsoft.com/v1.0/me/sendMail' -tenantid $env:TenantID -NoAuthCheck $true -type POST -body ($JSONBody)
                    Write-LogMessage -API $APIName -message "Sent Autopilot device alert email to support@baytechnologies.tech" -tenant $($Request.body.TenantFilter.value) -sev Info
                } catch {
                    Write-LogMessage -headers $Request.Headers -API $APIName -tenant $($Request.body.TenantFilter.value) -message "Failed to send email alert: $($_.Exception.Message)" -Sev 'Warning'
                }

                # Also send PSA alert if configured
                $PSAAlert = @{
                    Type = 'psa'
                    Title = $HTMLContent.title
                    HTMLContent = $HTMLContent.htmlcontent
                    TenantFilter = $Request.body.TenantFilter.value
                    APIName = $APIName
                    Headers = $Request.Headers
                }
                Send-CIPPAlert @PSAAlert
                
                Write-LogMessage -headers $Request.Headers -API $APIName -tenant $($Request.body.TenantFilter.value) -message "Sent Autopilot device addition alert for $($ProcessedDevices.Count) device(s)" -Sev 'Info'
            }
        } catch {
            Write-LogMessage -headers $Request.Headers -API $APIName -tenant $($Request.body.TenantFilter.value) -message "Failed to send Autopilot device addition alert: $($_.Exception.Message)" -Sev 'Warning'
        }

        [PSCustomObject]@{
            Status  = 'Import Job Completed'
            Devices = @($NewStatus.devicesStatus)
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $StatusCode = [HttpStatusCode]::InternalServerError
        [PSCustomObject]@{
            Status  = "$($Request.Body.TenantFilter.value): Failed to create autopilot devices. $($ErrorMessage.NormalizedError)"
            Devices = @()
        }
        Write-LogMessage -headers $Headers -API $APIName -tenant $($Request.Body.TenantFilter.value) -message "Failed to create autopilot devices. $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{'Results' = $Result }
        })
}

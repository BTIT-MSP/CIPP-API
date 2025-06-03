using namespace System.Net

Function Invoke-AddAPDevice {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.Autopilot.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    Write-LogMessage -headers $Headers -API $APIName -message 'Accessed this API' -Sev 'Debug'



    $TenantFilter = (Get-Tenants | Where-Object { $_.defaultDomainName -eq $Request.body.TenantFilter.value }).customerId
    $GroupName = if ($Request.body.Groupname) { $Request.body.Groupname } else { (New-Guid).GUID }
    Write-Host $GroupName
    $rawDevices = $request.body.autopilotData
    $Devices = ConvertTo-Json @($rawDevices)
    $Result = try {
        $CurrentStatus = (New-GraphgetRequest -uri "https://api.partnercenter.microsoft.com/v1/customers/$tenantfilter/DeviceBatches" -scope 'https://api.partnercenter.microsoft.com/user_impersonation')
        if ($groupname -in $CurrentStatus.items.id) {
            Write-Host 'Gonna do an update!'
            $body = $request.body.autopilotData | ForEach-Object {
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
            $body = ConvertTo-Json -Depth 10 -Compress -InputObject @($body)
            Write-Host $body
            $GraphRequest = (New-GraphPostRequest -returnHeaders $true -uri "https://api.partnercenter.microsoft.com/v1/customers/$TenantFilter/deviceBatches/$groupname/devices" -body $body -scope 'https://api.partnercenter.microsoft.com/user_impersonation')
        } else {
            $body = '{"batchId":"' + $($GroupName) + '","devices":' + $Devices + '}'
            $GraphRequest = (New-GraphPostRequest -returnHeaders $true -uri "https://api.partnercenter.microsoft.com/v1/customers/$TenantFilter/DeviceBatches" -body $body -scope 'https://api.partnercenter.microsoft.com/user_impersonation')
        }
        $Amount = 0
        do {
            Write-Host "Checking status of import job for $GroupName"
            $amount ++
            Start-Sleep 1
            $NewStatus = New-GraphgetRequest -uri "https://api.partnercenter.microsoft.com/v1/$($GraphRequest.Location)" -scope 'https://api.partnercenter.microsoft.com/user_impersonation'
        } until ($Newstatus.status -eq 'finished' -or $amount -eq 4)
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
    } catch {
        [PSCustomObject]@{
            Status  = "$($Request.body.TenantFilter.value): Failed to create autopilot devices. $($_.Exception.Message)"
            Devices = @()
        }
        Write-LogMessage -headers $Request.Headers -API $APIName -tenant $($Request.body.TenantFilter.value) -message "Failed to create autopilot devices. $($_.Exception.Message)" -Sev 'Error'
    }

    $body = [pscustomobject]@{'Results' = $Result }
    Write-Host $body
    # Associate values to output bindings by calling 'Push-OutputBinding'.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $body

        })

}

function New-ConnectWisePSATicket {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        $title,
        $description,
        $client
    )
    #Get ConnectWise Token based on the config we have.
    $Table = Get-CIPPTable -TableName Extensionsconfig
    $Configuration = ((Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json).ConnectWise
    $TicketTable = Get-CIPPTable -TableName 'PSATickets'
    $Headers = Get-ConnectWiseToken -configuration $Configuration
    # sha hash title
    $TitleHash = Get-StringHash -String $title

    if ($Configuration.ConsolidateTickets) {
        $ExistingTicket = Get-CIPPAzDataTableEntity @TicketTable -Filter "PartitionKey eq 'ConnectWise' and RowKey eq '$($client)-$($TitleHash)'"
        if ($ExistingTicket) {
            Write-Information "Ticket already exists in ConnectWise: $($ExistingTicket.TicketID)"

            $Ticket = Invoke-RestMethod -Uri "$($Configuration.ServerURL)/v4_6_release/apis/3.0/service/tickets/$($ExistingTicket.TicketID)" -ContentType 'application/json; charset=utf-8' -Method Get -Headers $Headers
            if ($Ticket.status.name -ne 'Closed') {
                Write-Information 'Ticket is still open, adding new note'
                $Object = [PSCustomObject]@{
                    ticketId                = $ExistingTicket.TicketID
                    text                    = $description
                    internalAnalysisFlag    = $true
                    resolution              = $false
                }
                $body = ConvertTo-Json -Compress -Depth 10 -InputObject $Object
                try {
                    if ($PSCmdlet.ShouldProcess('Add note to ConnectWise ticket', 'Add note')) {
                        $Note = Invoke-RestMethod -Uri "$($Configuration.ServerURL)/v4_6_release/apis/3.0/service/tickets/$($ExistingTicket.TicketID)/notes" -ContentType 'application/json; charset=utf-8' -Method Post -Body $body -Headers $Headers
                        Write-Information "Note added to ticket in ConnectWise: $($ExistingTicket.TicketID)"
                    }
                    return "Note added to ticket in ConnectWise: $($ExistingTicket.TicketID)"
                } catch {
                    $Message = if ($_.ErrorDetails.Message) {
                        Get-NormalizedError -Message $_.ErrorDetails.Message
                    } else {
                        $_.Exception.message
                    }
                    Write-LogMessage -message "Failed to add note to ConnectWise ticket: $Message" -API 'ConnectWisePSATicket' -sev Error -LogData (Get-CippException -Exception $_)
                    Write-Information "Failed to add note to ConnectWise ticket: $Message"
                    Write-Information "Body we tried to ship: $body"
                    return "Failed to add note to ConnectWise ticket: $Message"
                }
            }
        }
    }

    # Create new ticket object for ConnectWise
    $Object = [PSCustomObject]@{
        summary     = $title
        initialDescription = $description
        company     = @{
            id = [int]($client | Select-Object -Last 1)
        }
        recordType  = 'ServiceTicket'
    }

    # Add board configuration if specified
    if ($Configuration.Board) {
        $Object | Add-Member -MemberType NoteProperty -Name 'board' -Value @{
            id = [int]$Configuration.Board
        } -Force
    }

    # Add status configuration if specified  
    if ($Configuration.Status) {
        $Object | Add-Member -MemberType NoteProperty -Name 'status' -Value @{
            id = [int]$Configuration.Status
        } -Force
    }

    # Add type configuration if specified
    if ($Configuration.Type) {
        $Object | Add-Member -MemberType NoteProperty -Name 'type' -Value @{
            id = [int]$Configuration.Type
        } -Force
    }

    # Add priority configuration if specified
    if ($Configuration.Priority) {
        $Object | Add-Member -MemberType NoteProperty -Name 'priority' -Value @{
            id = [int]$Configuration.Priority
        } -Force
    }

    # Create the ticket in ConnectWise
    $body = ConvertTo-Json -Compress -Depth 10 -InputObject $Object

    Write-Information 'Sending ticket to ConnectWise'
    Write-Information $body
    try {
        if ($PSCmdlet.ShouldProcess('Send ticket to ConnectWise', 'Create ticket')) {
            $Ticket = Invoke-RestMethod -Uri "$($Configuration.ServerURL)/v4_6_release/apis/3.0/service/tickets" -ContentType 'application/json; charset=utf-8' -Method Post -Body $body -Headers $Headers
            Write-Information "Ticket created in ConnectWise: $($Ticket.id)"

            if ($Configuration.ConsolidateTickets) {
                $TicketObject = [PSCustomObject]@{
                    PartitionKey = 'ConnectWise'
                    RowKey       = "$($client)-$($TitleHash)"
                    Title        = $title
                    ClientId     = $client
                    TicketID     = $Ticket.id
                }
                Add-CIPPAzDataTableEntity @TicketTable -Entity $TicketObject -Force
                Write-Information 'Ticket added to consolidation table'
            }
            return "Ticket created in ConnectWise: $($Ticket.id)"
        }
    } catch {
        $Message = if ($_.ErrorDetails.Message) {
            Get-NormalizedError -Message $_.ErrorDetails.Message
        } else {
            $_.Exception.message
        }
        Write-LogMessage -message "Failed to send ticket to ConnectWise: $Message" -API 'ConnectWisePSATicket' -sev Error -LogData (Get-CippException -Exception $_)
        Write-Information "Failed to send ticket to ConnectWise: $Message"
        Write-Information "Body we tried to ship: $body"
        return "Failed to send ticket to ConnectWise: $Message"
    }
}
<#
.SYNOPSIS
This script is designed to create information barrier policies for each administrative unit and security groups from an O365 tenant.

.DESCRIPTION
This script will read from Azure, and output the administrative units and security groups to CSVs.  Afterwards, you are prompted to confirm that you want to create the organization segments needed, then create and apply the information barrier policies.  A folder will be created in the same directory as the script itself and contains a log file which details the organization segments and information barrier policies created.  The rows of the csv files can be reduced to only target specific administrative units and security groups.  Nextlink in the log can be used for the skipToken script parameter to continue where the script left off in case it does not finish.

.PARAMETER upns
Upn used for Connect-IPPSSession to try to avoid reentering credentials when renewing connection.  Multiple upns separated by commas can be used for parallel jobs. Recommend the maximum amount of 3 for large datasets.

.PARAMETER all
Executes script without confirmation prompts

.PARAMETER auOrgSeg
Bypasses confirmation prompt to create organization segments from records in the administrative units file.

.PARAMETER auIB
Bypasses confirmation prompt to create information barriers from records in the administrative units file.

.PARAMETER sgOrgSeg
Bypasses confirmation prompt to create organization segments from records in the security groups file.

.PARAMETER sgIB
Bypasses confirmation prompt to create information barriers from records in the security groups file.

.PARAMETER csvFilePathAU

The path for the csv file containing the administrative units in the tenant.  When provided, the script will attempt to create the organization segments and information barrier policies from the records in the file.  Each record should contain the AAD ObjectId and DisplayName.

.PARAMETER csvFilePathSG

The path for the csv file containing the security groups in the tenant.  When provided, the script will attempt to create the organization segments and information barrier policies from the records in the file.  Each record should contain the AAD ObjectId and DisplayName.

.PARAMETER maxParallelJobs 

Maximum number of jobs to run in parallel using ExchangeOnline Module.  We use 1 job per session.  Max sessions is 3 for ExchangeOnline.

.PARAMETER maxAttempts

Number of times we attempt to add all compliance objects.

.PARAMETER maxTimePerAttemptMins

Maximum time allowed to attempt to add all compliance objects using parallel jobs.  May need to adjust to several hours for large datasets.

.PARAMETER skipToken

Used to start where the script left off fetching the users in case of interruption.  The value used is nextLink in the log file, otherwise use default value of "" to start from the beginning.

.PARAMETER outFolder

Path where to put the log and csv file with the fetched data from Graph.

.PARAMETER graphVersion

The version of the Graph API.

.EXAMPLE
PS> .\Create-non_SDS_Information_Barriers.ps1

.NOTES
========================
 Required Prerequisites
========================

1. This script uses features that require Information Barriers version 3 or above to be enabled in your tenant.

    a. Existing Organization Segments and Information Barriers created by a legacy version should be removed prior to upgrading.

2. Install Microsoft Graph Powershell Module and Exchange Online Management Module with commands 'Install-Module Microsoft.Graph' and 'Install-Module ExchangeOnlineManagement'

3. Check that you can connect to your tenant directory from the PowerShell module to make sure everything is set up correctly.

    a. Open a separate PowerShell session

    b. Execute: "connect-graph -scopes AdministrativeUnit.ReadWrite.All, Group.ReadWrite.All, Directory.ReadWrite.All" to bring up a sign-in UI.

    c. Sign in with any tenant administrator credentials

    d. If you are returned to the PowerShell session without error, you are correctly set up.

4.  Retry this script.  If you still get an error about failing to load the Microsoft Graph module, troubleshoot why "Import-Module Microsoft.Graph.Authentication -MinimumVersion 0.9.1" isn't working and do the same for the Exchange Online Management Module.
#>

Param (
    [Parameter(Mandatory=$false)]
    [array] $upns,

    [Alias("a")]
    [switch]$all = $false,
    [switch]$auOrgSeg = $false,
    [switch]$auIB = $false,
    [switch]$sgOrgSeg = $false,
    [switch]$sgIB = $false,
    [int]$maxParallelJobs = 3,
    [int]$maxAttempts = 1,
    [int]$maxTimePerAttemptMins = 180,
    [Parameter(Mandatory=$false)]
    [string] $skipToken= "",
    [Parameter(Mandatory=$false)]
    [string] $csvFilePathAU = "",
    [Parameter(Mandatory=$false)]
    [string] $csvFilePathSG = "",
    [Parameter(Mandatory=$false)]
    [string] $outFolder = ".\non_SDS_InformationBarriers",
    [Parameter(Mandatory=$false)]
    [string] $graphVersion = "beta",
    [switch] $PPE = $false
)

$graphEndpointProd = "https://graph.microsoft.com"
$graphEndpointPPE = "https://graph.microsoft-ppe.com"

# Used for refreshing connection
$connectTypeGraph = "Graph"
$connectTypeIPPSSession = "IPPSSession"
$connectGraphDT = Get-Date -Date "1970-01-01T00:00:00"
$connectIPPSSessionDT = Get-Date -Date "1970-01-01T00:00:00"

# Try to use the most session time for large datasets
$timeout = (New-Timespan -Hours 0 -Minutes 0 -Seconds 43200)
$pssOpt = new-PSSessionOption -IdleTimeout $timeout.TotalMilliseconds

function Set-Connection($connectDT, $connectionType) {

    # Check if need to renew connection
    $currentDT = Get-Date
    $lastRefreshedDT = $connectDT

    if ((New-TimeSpan -Start $lastRefreshedDT -End $currentDT).TotalMinutes -gt $timeout.TotalMinutes)
    {
        if ($connectionType -ieq $connectTypeIPPSSession)
        {
            $sessionIPPS = Get-PSSession | Where-Object {$_.ConfigurationName -eq "Microsoft.Exchange" -and $_.State -eq "Opened"}

            # Exchange Online allows 3 sessions max
            if ($sessionIPPS.count -eq 3) 
            {
                Disconnect-ExchangeOnline -confirm:$false | Out-Null
            }
            else {   
                if (!($upns))
                {
                    Connect-IPPSSession -PSSessionOption $pssOpt | Out-Null
                }
                else
                {
                    Connect-IPPSSession -PSSessionOption $pssOpt -UserPrincipalName $upn[0] | Out-Null
                }
            }
        }
        else
        {
            Connect-Graph -scopes $graphScopes | Out-Null

             # Get upn for Connect-IPPSSession to avoid entering again
            if (!($upns))
            {
                $connectedGraphUser = Invoke-GraphRequest -method get -uri "$graphEndpoint/$graphVersion/me"
                $connectedGraphUPN = $connectedGraphUser.userPrincipalName
                $upns = $connectedGraphUPN
            }
        }
    }
    return Get-Date
}

function Get-AUsAndSGs ($aadObjectType) {

        $csvFilePath = "$outFolder\$aadObjectType.csv"

        # Removes csv file unless link is provided to resume
        if ((Test-Path $csvFilePath) -and ($skipToken -eq ""))
        {
            Remove-Item $csvFilePath;
        }

        $pageCnt = 1 # counts the number of pages of SGs retrieved

        # Uri string for AU's
        $auUri = "$graphEndPoint/$graphVersion/directory/administrativeUnits?`$select=id,displayName,extension_fe2174665583431c953114ff7268b7b3_Education_ObjectType"

        # Preparing uri string for groups
        $grpSelectClause = "`$select=id,displayName,extension_fe2174665583431c953114ff7268b7b3_Education_ObjectType"
        $grpUri = "$graphEndPoint/$graphVersion/groups?`$filter=securityEnabled%20eq%20true&$grpSelectClause"

        # Determine either AU or SG uri to use
        switch ($aadObjectType) {
            $aadObjAU {
                $graphUri = $auUri
            }
            $aadObjSG {
                $graphUri = $grpUri
            }
        }

        Write-Progress -Activity "Reading AAD" -Status "Fetching $aadObjectType's"

        do {
            if ($skipToken -ne "" ) {
                $graphUri = $skipToken
            }

            $recordList = @() # Array of objects for SGs

            $response = Invoke-GraphRequest -Uri $graphUri -Method GET
            $records = $response.value

            $ctr = 0 # Counter for security groups retrieved

            foreach ($record in $records) {
                    $recordList += [pscustomobject]@{"ObjectId"=$record.Id;"DisplayName"=$record.DisplayName}
                    $ctr++
            }

            $recordList | Export-Csv $csvFilePath -Append -NoTypeInformation
            Write-Progress -Activity "Retrieving $aadObjectType's..." -Status "Retrieved $ctr $aadObjectType's from $pageCnt pages"

            # Write nextLink to log if need to restart from previous page
            Write-Output "[$(Get-Date -Format G)] Retrieved page $pageCnt of $aadObjectType's. nextLink: $($response.'@odata.nextLink')" | Out-File $logFilePath -Append
            $pageCnt++
            $skipToken = $response.'@odata.nextLink'

        } while ($response.'@odata.nextLink')
    return $csvFilePath
}

$NewOrgSegmentsJob = {

    Param ($aadObjs, $aadObjectType, $startIndex, $count, $thisJobId, $defaultDelay, $addDelay, $timeout, $upn, $logFilePath, $aadObjAU, $aadObjSG)

    $sb = [System.Text.StringBuilder]::new()

    $pssOptJob = new-PSSessionOption -IdleTimeout $timeout.TotalMilliseconds
    
    $delay = $defaultDelay
    
    for ($i = $startIndex; $i -lt $startIndex+$count; $i++)
    {

        $aadObj = $aadObjs[$i]
        $displayName = $aadObj.DisplayName
        $objectId = $aadObj.ObjectId
        
        $currentJobDt = Get-Date
        
        # Check if need to renew connection
        if ($lastJobRefreshedDT -eq $null -or (New-TimeSpan -Start $lastJobRefreshedDT -End $currentJobDT).TotalMinutes -gt $timeout.TotalMinutes)
        {
            $sessionJobIPPS = Get-PSSession | Where-Object {$_.ConfigurationName -eq "Microsoft.Exchange" -and $_.State -eq "Opened"}

            # Exchange Online allows 3 sessions max
            if ($sessionJobIPPS.count -eq 3) 
            {
                Disconnect-ExchangeOnline -confirm:$false | Out-Null
            }

            Connect-IPPSSession -PSSessionOption $pssOptJob -UserPrincipalName $upn | Out-Null
            $lastJobRefreshedDT = Get-Date
        }

        switch ($aadObjectType) {
            $aadObjAU {
                Write-Output "[$($i-$startIndex+1)/$count/$thisJobId] [$(Get-Date -Format G)] Creating organization segment $displayName ($objectId) from $aadObjectType with $upn"
                $logstr = Invoke-Command { New-OrganizationSegment -Name $displayName -UserGroupFilter "AdministrativeUnits -eq '$($objectId)'" } -ErrorAction Stop -ErrorVariable err -WarningAction SilentlyContinue -WarningVariable warning | Select-Object WhenCreated, WhenChanged, Type, Name, Guid | ConvertTo-json -compress
            }
            $aadObjSG {
                Write-Output "[$($i-$startIndex+1)/$count/$thisJobId] [$(Get-Date -Format G)] Creating organization segment $displayName ($objectId) from $aadObjectType with $upn"
                $logstr = Invoke-Command { New-OrganizationSegment -Name $displayName -UserGroupFilter "MemberOf -eq '$($objectId)'" } -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable warning | Select-Object WhenCreated, WhenChanged, Type, Name, Guid | ConvertTo-json -compress
            }
        }

        $sb.AppendLine($logstr) | Out-Null
                
        if ($err) 
        {
            $sb.AppendLine("[$(Get-Date -Format G)] Error: " + $err) | Out-Null
        }
        
        if ($warning | Select-String -Pattern 'delay' -SimpleMatch )
        {
            $delay += $addDelay
        }
        else 
        {
            $delay = $defaultDelay
        }

        Start-Sleep -Seconds $delay
    }

    $sb.ToString() | Out-File $logFilePath -Append
}

$NewInformationBarriersJob = {

    Param ($aadObjs, $aadObjectType, $startIndex, $count, $thisJobId, $defaultDelay, $addDelay, $timeout, $upn, $logFilePath)

    $sb = [System.Text.StringBuilder]::new()

    $pssOptJob = new-PSSessionOption -IdleTimeout $timeout.TotalMilliseconds

    $delay = $defaultDelay

    for ($i = $startIndex; $i -lt $startIndex+$count; $i++)
    {
        $aadObj = $aadObjs[$i]
        $displayName = $aadObj.DisplayName
        $objectId = $aadObj.ObjectId

        $currentJobDt = Get-Date

        # Check if need to renew connection
        if ($lastJobRefreshedDT -eq $null -or (New-TimeSpan -Start $lastJobRefreshedDT -End $currentJobDT).TotalMinutes -gt $timeout.TotalMinutes)
        {
            $sessionJobIPPS = Get-PSSession | Where-Object {$_.ConfigurationName -eq "Microsoft.Exchange" -and $_.State -eq "Opened"}

            # Exchange Online allows 3 sessions max
            if ($sessionJobIPPS.count -eq 3) 
            {
                Disconnect-ExchangeOnline -confirm:$false | Out-Null
            }

            Connect-IPPSSession -PSSessionOption $pssOptJob -UserPrincipalName $upn | Out-Null
            $lastJobRefreshedDT = Get-Date
        }

        Write-Output "[$($i-$startIndex+1)/$count/$thisJobId] [$(Get-Date -Format G)] Creating information barrier policy $displayName ($objectId) from $aadObjectType with $upn"
        $logstr = Invoke-Command { New-InformationBarrierPolicy -Name "$displayName - IB" -AssignedSegment $displayName -SegmentsAllowed $displayName -State Active -Force } -ErrorAction Stop -ErrorVariable err -WarningAction SilentlyContinue -WarningVariable warning | Select-Object WhenCreated, WhenChanged, Type, Name, Guid | ConvertTo-json -compress
        $sb.AppendLine($logstr) | Out-Null

        if ($err) 
        {
            $sb.AppendLine("[$(Get-Date -Format G)] Error: " + $err) | Out-Null
        }

        if ($warning | Select-String -Pattern 'delay' -SimpleMatch )
        {
            $delay += $addDelay
        }
        else 
        {
            $delay = $defaultDelay
        }

        Start-Sleep -Seconds $delay
    }

    $sb.ToString() | Out-File $logFilePath -Append  
}

function Get-Confirmation ($ippsObjectType, $aadObjectType, $csvfilePath) {
    
    switch ($ippsObjectType) {
        $ippsObjOS {
            $ippsObjText = 'organization segments'
        }
        $ippsObjIB {
            $ippsObjText = 'information barrier policies'
        }
    }

    Write-Host "`nYou are about to create $ippsObjText from $aadObjectType's. `nIf you want to skip any $aadObjectType's, edit the file now and remove the corresponding lines before proceeding. `n" -ForegroundColor Yellow
    Write-Host "Proceed with creating an $ippsObjText from $aadObjectType's logged in $csvfilePath (yes/no) or ^+c to exit script?" -ForegroundColor Yellow
    
    $choice = Read-Host
    return $choice
}

function Add-AllIPPSObjects($ippsObjectType, $aadObjectType, $csvFilePath)
{
    Write-Host "`n=====================================================" -ForegroundColor Cyan
    Write-Host "Adding $objectType in Tenant" -ForegroundColor Cyan
    
    $jobDelay = 30;
    $addJobDelay = 15;
    $attempts = 1;

    while ($true)
    {
        $scriptBlock = $null
        $aadObjects = $null
        $totalObjectCount = 0
        $loopStartTime = Get-Date

        switch ($ippsObjectType)
        {
            $ippsObjOS
            {
                $scriptBlock = $NewOrgSegmentsJob
                $aadObjects = Import-Csv $csvFilePath
            }
            $ippsObjIB
            {
                $scriptBlock = $NewInformationBarriersJob
                $aadObjects = Import-Csv $csvFilePath
            }
        }

        $totalObjectCount = $aadObjects.count
        Write-Host "Creating $totalObjectCount $ippsObjectType's from $aadObjectType's. [Attempt #$attempts]" -ForegroundColor Green

        if ($attempts -gt $maxAttempts)
        {
            Write-Host "`nDone adding $objectType `n" -ForegroundColor Green
            break;
        }
        else
        {
            if ($attempts -gt 1)
            {
                Write-Host "`n Could not remove all $objectType's. Giving up after $attempts attempts.`n" -ForegroundColor Red
                break;
            }
        }

        # Split task into equal sized jobs and start executing in parallel
        $startIndex = 0
        [Int]$jobSize = [math]::truncate($totalObjectCount / $maxParallelJobs)
        [Int]$remainder = $totalObjectCount % $maxParallelJobs

        for ($i = 0; $i -lt $maxParallelJobs -and $i -lt $totalObjectCount; $i++)
        {
            $count = $jobSize
            if ($remainder -gt 0)
            {
                $count++
                $Remainder--
            }

            $jobID = $i+1
            $sessionNum = $i
     
            Write-Host "Spawning job $jobID to add $count $ippsObjectType's starting at $startIndex; End Index: $($startIndex+$count-1)" -ForegroundColor Cyan
            Start-Job $scriptBlock -ArgumentList $aadObjects, $aadObjectType, $startIndex, $count, $jobID, $jobDelay, $addJobDelay, $timeout, $upns[$sessionNum], $logFilePath, $aadObjAU, $aadObjSG
            $startIndex += $count
        }

        $currentTimeInLoop = Get-Date
        $timeInLoopMins = ($currentTimeInLoop - $loopStartTime).Minutes
        
        # Wait for all jobs to complete or till time out
        While ((Get-Job -State "Running") -and $timeInLoopMins -le $maxTimePerAttemptMins)
        {
            # Display output from all jobs every 10 seconds
            Get-Job | Receive-Job
            Write-Host ""
            Start-Sleep 10
        }

        if ($timeInLoopMins -gt $maxTimePerAttemptMins)
        {
            Write-Host "Attempt timed out, removing any hung jobs" -ForegroundColor Yellow
        }

        # Clean-up any hung jobs
        Get-Job | Receive-Job
        Stop-Job *
        Remove-Job * -Force

        $attempts = $attempts + 1;
    }
}

# Main
$graphEndPoint = $graphEndpointProd

if ($PPE)
{
    $graphEndPoint = $graphEndpointPPE
}

$logFilePath = "$outFolder\create_non_SDS_InformationBarriers.log"

$aadObjAU = "AU"
$aadObjSG = "SG"
$ippsObjOS = 'OS'
$ippsObjIB = "IB"

# List used to request access to data
$graphScopes = "AdministrativeUnit.ReadWrite.All, Group.ReadWrite.All, Directory.ReadWrite.All"

try 
{
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 0.9.1 | Out-Null
}
catch
{
    Write-Error "Failed to load Microsoft Graph PowerShell Module."
    Get-Help -Name .\Create-non_SDS_Information_Barriers.ps1 -Full | Out-String | Write-Error
    throw
}

try 
{
    Import-Module ExchangeOnlineManagement | Out-Null
}
catch
{
    Write-Error "Failed to load Exchange Online Management Module for creating Information Barriers"
    Get-Help -Name .\Create-non_SDS_Information_Barriers.ps1 -Full | Out-String | Write-Error
    throw
}

# Create output folder if it does not exist
if ((Test-Path $outFolder) -eq 0) {
    mkdir $outFolder | Out-Null;
}

Write-Host "`nActivity logged to file $logFilePath `n" -ForegroundColor Green

if ( $all -or $csvFilePathAU -eq "" ) {
    $connectGraphDT = Set-Connection $connectGraphDT $connectTypeGraph
    $csvFilePathAU = Get-AUsAndSGs $aadObjAU
}

if ( $csvFilePathAU -ne "" ) {
    if (Test-Path $csvFilePathAU) {
        if ( $all -or $auOrgSeg )
        {   
            Add-AllIPPSObjects $ippsObjOS $aadObjAU $csvFilePathAU
        }
        else
        {
            $choiceAUOS = Get-Confirmation $ippsObjOS $aadObjAU $csvFilePathAU
            if ($choiceAUOS -ieq "y" -or $choiceAUOS -ieq "yes") {
                Add-AllIPPSObjects $ippsObjOS $aadObjAU $csvFilePathAU
            }     
        }
        
        if ($all -or $auIB)
        {
            Add-AllIPPSObjects $ippsObjIB $aadObjAU $csvFilePathAU
        }
        else
        {
            $choiceAUIB = Get-Confirmation $ippsObjIB $aadObjAU $csvFilePathAU
            if ($choiceAUIB -ieq "y" -or $choiceAUIB -ieq "yes") {
                Add-AllIPPSObjects $ippsObjIB $aadObjAU $csvFilePathAU
            }     
        }
    }
    else {
        Write-Error "Path for $csvFilePathAU is not found."
    }
}

if ( $all -or $csvFilePathSG -eq "" ) {
    $connectGraphDT = Set-Connection $connectGraphDT $connectTypeGraph
    $csvFilePathSG = Get-AUsAndSGs $aadObjSG
}

if ( $all -or $csvFilePathSG -ne "" ) {
    if (Test-Path $csvFilePathSG) {
        if ($all -or $sgOrgSeg)
        {
            Add-AllIPPSObjects $ippsObjOS $aadObjSG $csvFilePathSG
        }
        else
        {
            $choiceSGOS = Get-Confirmation $ippsObjOS $aadObjSG $csvFilePathSG
            if ($choiceSGOS -ieq "y" -or $choiceSGOS -ieq "yes") {
                Add-AllIPPSObjects $ippsObjOS $aadObjSG $csvFilePathSG
            }     
        }

        if ($all -or $sgIB)
        {
            Add-AllIPPSObjects $ippsObjIB $csvFilePathSG
        }
        else
        {
            $choiceIBSG = Get-Confirmation $ippsObjIB $aadObjSG $csvFilePathSG
            if ($choiceIBSG -ieq "y" -or $choiceIBSG -ieq "yes") {
                Add-AllIPPSObjects $ippsObjIB $aadObjSG $csvFilePathSG
            }     
        }
    }
    else {
        Write-Error "Path for $csvFilePathSG is not found."
    }
}

if ( !($all) ) {
    Write-Host "`nProceed with starting the information barrier policies application (yes/no)?" -ForegroundColor Yellow
    $choiceStartIB = Read-Host
}
else{
    $choiceStartIB = "y"
}

if ($choiceStartIB -ieq "y" -or $choiceStartIB -ieq "yes") {
    $connectTypeIPPSSession = Set-Connection $connectIPPSSessionDT $connectTypeIPPSSession
    Start-InformationBarrierPoliciesApplication | Out-Null
    Write-Output "Done.  Please allow ~30 minutes for the system to start the process of applying Information Barrier Policies. `nUse Get-InformationBarrierPoliciesApplicationStatus to check the status"
}

Write-Output "`n`nDone.  Please run 'Disconnect-Graph' and 'Disconnect-ExchangeOnline' if you are finished`n"

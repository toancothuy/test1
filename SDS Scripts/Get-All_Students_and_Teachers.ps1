﻿<#
Script Name:
Get-All_Students_and_Teachers.ps1

Synopsis:
Description: This script is designed to export all students and teachers, into 2 CSV files (Student.csv and Teacher.csv). This script contains a mix of SDS attributes and standard Azure user object attributes. 

Syntax Examples and Options:
.\Get-All_Students_and_Teachers.ps1

Written By: 
Orginal/Full Script written by TJ Vering. This script was adapted from the orginal by Bill Sluss.

Change Log:
Version 1.0, 12/06/2016 - First Draft
Version 2.0, 03/09/2022 - Change to MS Graph Module - Tim McCall

#>

Param (
    [string] $ExportSchools = $true,
    [string] $ExportStudents = $true,
    [string] $ExportTeachers = $true,
    [string] $ExportSections = $true,
    [string] $ExportStudentEnrollments = $true,

    [string] $ExportTeacherRosters = $true,
    [string] $OutFolder = "./StudentsTeachersExport",
    [switch] $PPE = $false,
    [switch] $AppendTenantIdToFileName = $false,
    [Parameter(Mandatory=$false)]
    [string] $skipToken= ".",
    [Parameter(Mandatory=$false)]
    [switch] $downloadCommonFNs = $true

    # [string] $ExportTeacherRosters = $true,
    # [string] $OutFolder = ".",
    # [switch] $PPE = $false,
    # [switch] $AppendTenantIdToFileName = $false
)

$GraphEndpointProd = "https://graph.windows.net"
$GraphEndpointPPE = "https://graph.ppe.windows.net"

$logFilePath = $OutFolder

$eduObjTeacher = "Teacher"
$eduObjStudent = "Student"

function Get-PrerequisiteHelp
{
    Write-Output @"
========================
 Required Prerequisites
========================

1. Install Microsoft Graph Powershell Module with command 'Install-Module Microsoft.Graph'

2. Make sure to download common.ps1 to the same folder of the script which has common functions needed.  https://github.com/OfficeDev/O365-EDU-Tools/blob/master/SDS%20Scripts/common.ps1

3. Check that you can connect to your tenant directory from the PowerShell module to make sure everything is set up correctly.
    
    a. Open a separate PowerShell session
    
    b. Execute: "connect-graph -scopes User.Read.All, GroupMember.Read.All, Member.Read.Hidden, Group.Read.All, Directory.Read.All, AdministrativeUnit.Read.All" to bring up a sign in UI. 
    
    c. Sign in with any tenant administrator credentials
    
    d. If you are returned to the PowerShell sesion without error, you are correctly set up

4. Retry this script.  If you still get an error about failing to load the Microsoft Graph module, troubleshoot why "Import-Module Microsoft.Graph.Authentication -MinimumVersion 0.9.1" isn't working

5. Please visit the following link if a message is received that the license cannot be assigned.
   https://docs.microsoft.com/en-us/azure/active-directory/enterprise-users/licensing-groups-resolve-problems

(END)
========================
"@
}

function Export-SdsTeachers
{
    $fileName = $eduObjTeacher.ToLower() + $(if ($AppendTenantIdToFileName) { "-" + $authToken.TenantId } else { "" }) +".csv"
	$filePath = Join-Path $OutFolder $fileName
    Remove-Item -Path $filePath -Force -ErrorAction Ignore

    $data = Get-SdsTeachers

    $cnt = ($data | Measure-Object).Count
    if ($cnt -gt 0)
    {
        Write-Host "Exporting $cnt Teachers ..."
        $data | Export-Csv $filePath -Force -NotypeInformation
        Write-Host "`nTeachers exported to file $filePath `n" -ForegroundColor Green
        return $filePath
    }
    else
    {
        Write-Host "No Teachers found to export."
        return $null
    }
}

function Get-SdsTeachers
{
    $users = Get-Teachers
    $data = @()
    
    foreach($user in $users)
    {
        #DisplayName,UserPrincipalName,SIS ID,School SIS ID,Teacher Number,Status,Secondary Email
        $data += [pscustomobject]@{
            "DisplayName" = $user.DisplayName  
            "UserPrincipalName" = $user.userPrincipalName  
            "SIS ID" = $user.extension_fe2174665583431c953114ff7268b7b3_Education_SyncSource_TeacherId
            "School SIS ID" = $user.extension_fe2174665583431c953114ff7268b7b3_Education_SyncSource_SchoolId
            "Teacher Number" = $user.extension_fe2174665583431c953114ff7268b7b3_Education_TeacherNumber
            "Status" = $user.extension_fe2174665583431c953114ff7268b7b3_Education_TeacherStatus
            "Secondary Email" = $user.extension_fe2174665583431c953114ff7268b7b3_Education_Email
            "ObjectID" = $user.objectID
        }
    }
    return $data
}

function Get-Teachers
{
    return Get-Users $eduObjTeacher
}

function Export-SdsStudents
{
    $fileName = $eduObjStudent.ToLower() + $(if ($AppendTenantIdToFileName) { "-" + $authToken.TenantId } else { "" }) +".csv"
	$filePath = Join-Path $OutFolder $fileName
    Remove-Item -Path $filePath -Force -ErrorAction Ignore
    
    $data = Get-SdsStudents

    $cnt = ($data | Measure-Object).Count
    if ($cnt -gt 0)
    {
        Write-Host "Exporting $cnt Students ..."
        $data | Export-Csv $filePath -Force -NotypeInformation
        Write-Host "`nStudents exported to file $filePath `n" -ForegroundColor Green
        return $filePath
    }
    else
    {
        Write-Host "No Students found to export."
        return $null
    }
}
function Get-SdsStudents
{
    $users = Get-Students
    $data = @()

    foreach($user in $users)
    {
        #DisplayName,UserPrincipalName,SIS ID,School SIS ID,Student Number,Status,Secondary Email
        $data += [pscustomobject]@{
            "DisplayName" = $user.displayname
            "UserPrincipalName" = $user.userPrincipalName 
            "SIS ID" = $user.extension_fe2174665583431c953114ff7268b7b3_Education_SyncSource_StudentId
            "School SIS ID" = $user.extension_fe2174665583431c953114ff7268b7b3_Education_SyncSource_SchoolId
            "Student Number" = $user.extension_fe2174665583431c953114ff7268b7b3_Education_StudentNumber
            "Status" = $user.extension_fe2174665583431c953114ff7268b7b3_Education_StudentStatus
            "Secondary Email" = $user.extension_fe2174665583431c953114ff7268b7b3_Education_Email
            "ObjectID" = $user.ObjectID
        }
    }

    return $data
}

function Get-Students
{
    return Get-Users $eduObjStudent
}

function Get-Users
{
    Param
    (
        $eduObjectType
    )

    $list = @()

    $initialUri = "$graphEndPoint/beta/users?`$filter=extension_fe2174665583431c953114ff7268b7b3_Education_ObjectType%20eq%20'$eduObjectType'"

    $checkedUri = TokenSkipCheck $initialUri $logFilePath
    $users = PageAll-GraphRequest $checkedUri $refreshToken 'GET' $graphscopes $logFilePath

    foreach ($user in $users)
    {
        if ($null -ne $user.id)
        {
            $list += $user
        }
    }
    return $list
}

# Main
$graphEndPoint = $GraphEndpointProd

if ($PPE)
{
    $graphEndPoint = $GraphEndpointPPE
}

$activityName = "Reading SDS objects in the directory"

$graphscopes = "User.Read.All, GroupMember.Read.All, Member.Read.Hidden, Group.Read.All, Directory.Read.All, AdministrativeUnit.Read.All"

try
{
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 0.9.1 | Out-Null
}
catch
{
    Write-Error "Failed to load Microsoft Graph PowerShell Module."
    Get-PrerequisiteHelp | Out-String | Write-Error
    throw
}

# Connect to the tenant
Write-Progress -Activity $activityName -Status "Connecting to tenant"

Initialize

Write-Progress -Activity $activityName -Status "Connected. Discovering tenant information"
$tenantDomain = Get-MgDomain
$tenantInfo = Get-MgOrganization
$tenantId =  $tenantInfo.Id
$tenantDisplayName = $tenantInfo.DisplayName
$tenantdd =  $tenantDomain.Id

$StudentLicenses = (Get-MgSubscribedSku | Where-Object {$_.SkuPartNumber -match "STANDARDWOFFPACK_IW_STUDENT"}).consumedunits
$StudentLicensesApplied = ($StudentLicenses | Measure-Object -Sum).sum
$TeacherLicenses = (Get-MgSubscribedSku | Where-Object {$_.SkuPartNumber -match "STANDARDWOFFPACK_IW_FACULTY"}).consumedunits
$TeacherLicensesApplied = ($TeacherLicenses | Measure-Object -Sum).sum

# Create output folder if it does not exist
if ((Test-Path $OutFolder) -eq 0)
{
	mkdir $OutFolder;
}

# Export all User of Edu Object Type Teacher/Student
Write-Progress -Activity $activityName -Status "Fetching Teachers ..."
Export-SdsTeachers | Out-Null

Write-Progress -Activity $activityName -Status "Fetching Students ..."
Export-SdsStudents | Out-Null
    

#Write Tenant Details to the PS screen
Write-Host -foregroundcolor green "Tenant Name is $tenantDisplayName"
Write-Host -foregroundcolor green "TenantID is $tenantId"
Write-Host -foregroundcolor green "Tenant default domain is $tenantdd"


Write-Host "The number of student licenses currently applied is $StudentLicensesApplied"
Write-Host "The number of teacher licenses currently applied is $TeacherLicensesApplied"

Write-Output "`n`nDone.  Please run 'Disconnect-Graph' if you are finished.`n"
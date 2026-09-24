# PharmaSecure IAM Automation
# Fictional pharmaceutical IAM lab
# Purpose: Detect and revoke expired temporary access

# Determine project root from script location

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path $PSScriptRoot -Parent

# Portable project paths
$AccessRegisterPath = Join-Path $ProjectRoot "evidence\PharmaSecure_Access_Register.csv"
$AuditFile = Join-Path $ProjectRoot "evidence\PharmaSecure_Audit_Evidence.csv"

# Verify Microsoft Graph connection
$GraphContext = Get-MgContext

if (-not $GraphContext) {
    Write-Error "Microsoft Graph authentication required. Connect to Microsoft Graph before running this automation."
    exit 1
}
# Import access register
$AccessRegister = Import-Csv $AccessRegisterPath

$Today = Get-Date "2026-10-02"

$AuditResults = @()

Write-Host ""
Write-Host "======================================"
Write-Host "PHARMASECURE IAM AUTOMATION"
Write-Host "======================================"
Write-Host "Evaluation Date: $($Today.ToString('MM/dd/yyyy'))"
Write-Host ""

foreach ($Request in $AccessRegister) {

    $Expiration = Get-Date $Request."End Date"
try {
    $User = Get-MgUser -Filter "displayName eq '$($Request.User)'"

    if (-not $User) {
        throw "User '$($Request.User)' was not found in Microsoft Entra ID."
    }

    $Group = Get-MgGroup -Filter "displayName eq 'IAM-RBAC-QMS-Temporary'"

    if (-not $Group) {
        throw "Required group 'IAM-RBAC-QMS-Temporary' was not found."
    }

    $Members = Get-MgGroupMember -GroupId $Group.Id -All

    $Access = $Members |
        Where-Object { $_.Id -eq $User.Id }
}
catch {
    Write-Host ""
    Write-Host "ERROR: Microsoft Graph operation failed."
    Write-Host "User: $($Request.User)"
    Write-Host "Details: $($_.Exception.Message)"
    Write-Host "Action: Record skipped to prevent an incorrect IAM decision."
    Write-Host "--------------------------------------"

    continue
}
    Write-Host "Request ID: $($Request."Request ID")"
    Write-Host "User: $($Request.User)"
    Write-Host "Application: $($Request.Application)"
    Write-Host "Expiration: $($Request."End Date")"

    if ($Expiration -lt $Today) {

        Write-Host "Status: EXPIRED"

        if ($Access) {

            Write-Host "Entra Access: PRESENT"
            Write-Host "Action: REVOKING TEMPORARY ACCESS"

           try {
    Remove-MgGroupMemberByRef `
        -GroupId $Group.Id `
        -DirectoryObjectId $User.Id

    $MembersAfter = Get-MgGroupMember `
        -GroupId $Group.Id `
        -All

    $AccessAfter = $MembersAfter |
        Where-Object { $_.Id -eq $User.Id }
}
catch {
    Write-Host "Result: REVOCATION FAILED"
    Write-Host "Details: $($_.Exception.Message)"

    $Result = "Revocation Failed"
    $Verification = "Graph Operation Failed"

    $AccessAfter = $true
}
           if ($Verification -eq "Graph Operation Failed") {
    # Preserve the Graph failure result
}
elseif ($AccessAfter) {
    $Result = "Revocation Failed"
    $Verification = "User Still In Temporary Group"
}
else {
    $Result = "Revocation Successful"
    $Verification = "Verified - User Removed From Temporary Group"
}
        }
        else {

            Write-Host "Entra Access: NOT PRESENT"
            Write-Host "Action: NO ACTION REQUIRED"

            $Result = "Access Already Revoked"
            $Verification = "Verified - User Not In Temporary Group"
        }
    }
    else {

        Write-Host "Status: ACTIVE"
        Write-Host "Action: NO ACTION REQUIRED"

        $Result = "Access Still Valid"
        $Verification = "Not Required"
    }

    Write-Host "Result: $Result"
    Write-Host "Verification: $Verification"
    Write-Host "--------------------------------------"

    $AuditResults += [PSCustomObject]@{
        "Request ID"      = $Request."Request ID"
        "User"            = $Request.User
        "Application"     = $Request.Application
        "Access Type"     = $Request.Access
        "Expiration Date" = $Request."End Date"
        "Evaluation Date" = $Today.ToString("MM/dd/yyyy")
        "Status"          = if ($Expiration -lt $Today) { "Expired" } else { "Active" }
        "Action"          = if ($Access) { "Temporary Access Revocation" } else { "No Action Required" }
        "Result"          = $Result
        "Verification"    = $Verification
    }
}

$AuditResults | Export-Csv $AuditFile -NoTypeInformation

Write-Host ""
Write-Host "AUDIT EVIDENCE CREATED:"
Write-Host $AuditFile
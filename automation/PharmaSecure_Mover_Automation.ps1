# ==========================================
# PharmaSecure IAM - Mover Automation
# Fictional pharmaceutical IAM laboratory
# Purpose: Process role changes and update RBAC access
# ==========================================

# Force terminating errors so Graph failures can be caught
$ErrorActionPreference = "Stop"

# Determine project root from script location
$ProjectRoot = Split-Path $PSScriptRoot -Parent

# Portable project paths
$JMLFile = Join-Path $ProjectRoot "evidence\PharmaSecure_JML_Register.csv"
$MoverAuditFile = Join-Path $ProjectRoot "evidence\PharmaSecure_Mover_Audit_Evidence.csv"

# Verify Microsoft Graph connection
$GraphContext = Get-MgContext

if (-not $GraphContext) {
    Write-Error "Microsoft Graph authentication required. Connect to Microsoft Graph before running this automation."
    exit 1
}

# Import JML register
try {
    $JMLRegister = Import-Csv $JMLFile
}
catch {
    Write-Error "Unable to import JML register: $($_.Exception.Message)"
    exit 1
}

# ==========================================
# RBAC Configuration
# ==========================================

# Maps approved department/job-title combinations
# to their corresponding Entra ID RBAC groups
$RBACMapping = @{
    "Laboratory|Lab Analyst"               = "IAM-RBAC-Lab-Analysts"
    "Quality|QA Specialist"                = "IAM-RBAC-QA"
    "R&D|Research Scientist"               = "IAM-RBAC-RD-Scientists"
    "Manufacturing|Manufacturing Operator" = "IAM-RBAC-Manufacturing"
    "HR|HR Specialist"                     = "IAM-RBAC-HR"
    "IT|Systems Administrator"             = "IAM-RBAC-IT-Admins"
}

# Job-role groups controlled by this JML workflow.
# Other IAM-RBAC groups, such as temporary access groups,
# are outside the scope of the Mover automation.
$ManagedRBACGroups = @(
    "IAM-RBAC-Lab-Analysts"
    "IAM-RBAC-QA"
    "IAM-RBAC-RD-Scientists"
    "IAM-RBAC-Manufacturing"
    "IAM-RBAC-HR"
    "IAM-RBAC-IT-Admins"
)

$AuditResults = @()

Write-Host ""
Write-Host "======================================"
Write-Host "PHARMASECURE MOVER AUTOMATION"
Write-Host "======================================"
Write-Host ""

foreach ($Request in $JMLRegister) {

    if ($Request.Status -eq "Pending" -and
        $Request."LifeCycle Event" -eq "Mover") {

        # Reset variables for each request
        $Result = $null
        $Verification = $null
        $TargetGroupName = $null
        $OldGroupName = "Unknown"
        $OldGroups = @()
        $User = $null
        $TargetGroup = $null
        $CurrentRBACGroups = @()

        Write-Host "Employee ID: $($Request.'Employee ID')"
        Write-Host "User: $($Request.User)"
        Write-Host "New Department: $($Request.Department)"
        Write-Host "New Job Title: $($Request.'Job Title')"
        Write-Host ""

        # ==========================================
        # Determine target RBAC group
        # ==========================================

        $MappingKey = "$($Request.Department)|$($Request.'Job Title')"
        $TargetGroupName = $RBACMapping[$MappingKey]

        Write-Host "Target RBAC Group: $TargetGroupName"
        Write-Host ""

        if (-not $TargetGroupName) {

            Write-Host "Result: FAILED - No RBAC mapping found"

            $Result = "Failed - No RBAC Mapping"
            $Verification = "Not Performed"
        }
        else {

            # ==========================================
            # Microsoft Graph discovery
            # ==========================================

            try {

                # Find user
                $User = Get-MgUser `
                    -Filter "displayName eq '$($Request.User)'"

                if (-not $User) {
                    throw "User '$($Request.User)' was not found in Microsoft Entra ID."
                }

                # Get user's current group memberships
                $CurrentGroups = Get-MgUserMemberOf `
                    -UserId $User.Id `
                    -All

                # Limit analysis to IAM RBAC groups
                $CurrentRBACGroups = $CurrentGroups |
                    Where-Object {
                        $_.AdditionalProperties.displayName -like "IAM-RBAC-*"
                    }

                # Identify obsolete managed job-role groups.
                # Temporary/special-purpose RBAC groups are intentionally ignored.
                $OldGroups = @(
                    $CurrentRBACGroups |
                        Where-Object {
                            $_.AdditionalProperties.displayName -in $ManagedRBACGroups -and
                            $_.AdditionalProperties.displayName -ne $TargetGroupName
                        }
                )

                if ($OldGroups.Count -gt 0) {

                    $OldGroupName = (
                        $OldGroups |
                            ForEach-Object {
                                $_.AdditionalProperties.displayName
                            }
                    ) -join "; "
                }
                else {
                    $OldGroupName = "None"
                }

                # Find target RBAC group
                $TargetGroup = Get-MgGroup `
                    -Filter "displayName eq '$TargetGroupName'"

                if (-not $TargetGroup) {
                    throw "Target RBAC group '$TargetGroupName' was not found."
                }
            }
            catch {

                Write-Host "Result: FAILED - Microsoft Graph lookup error"
                Write-Host "Details: $($_.Exception.Message)"
                Write-Host "Action: No access change performed"

                $Result = "Failed - Graph Lookup Error"
                $Verification = "Not Performed"
            }

            # Continue only if discovery succeeded
            if (-not $Result) {

                Write-Host "Current Managed RBAC Group(s): $OldGroupName"
                Write-Host "Target RBAC Group: $TargetGroupName"
                Write-Host ""

                # ==========================================
                # Determine whether target already exists
                # ==========================================

                $ExistingTargetAccess = $CurrentRBACGroups |
                    Where-Object {
                        $_.AdditionalProperties.displayName -eq $TargetGroupName
                    }

                # ==========================================
                # Remove obsolete RBAC memberships
                # ==========================================

                if ($OldGroups.Count -gt 0) {

                    Write-Host "Action: Removing obsolete job-role RBAC membership(s)"

                    try {

                        foreach ($OldGroup in $OldGroups) {

                            $GroupName = $OldGroup.AdditionalProperties.displayName

                            Write-Host "Removing: $GroupName"

                            Remove-MgGroupMemberByRef `
                                -GroupId $OldGroup.Id `
                                -DirectoryObjectId $User.Id

                            Write-Host "Removed: $GroupName"
                        }
                    }
                    catch {

                        Write-Host "Result: MOVER FAILED"
                        Write-Host "Details: Failed to remove obsolete RBAC membership."
                        Write-Host "Graph Error: $($_.Exception.Message)"

                        $Result = "Mover Failed - Old RBAC Removal"
                        $Verification = "Graph Removal Operation Failed"
                    }
                }
                else {
                    Write-Host "Obsolete Managed RBAC Access: NOT PRESENT"
                }

                # ==========================================
                # Add target RBAC membership
                # ==========================================

                if (-not $Result) {

                    if ($ExistingTargetAccess) {

                        Write-Host "Target RBAC Access: ALREADY PRESENT"
                        Write-Host "Action: No duplicate assignment required"
                    }
                    else {

                        Write-Host "Action: Adding target RBAC membership"

                        try {

                            New-MgGroupMemberByRef `
                                -GroupId $TargetGroup.Id `
                                -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($User.Id)"

                            Write-Host "New RBAC membership added"
                        }
                        catch {

                            Write-Host "Result: MOVER FAILED"
                            Write-Host "Details: Failed to add target RBAC membership."
                            Write-Host "Graph Error: $($_.Exception.Message)"

                            $Result = "Mover Failed - New RBAC Provisioning"
                            $Verification = "Graph Provisioning Operation Failed"
                        }
                    }
                }

                # ==========================================
                # Verify final RBAC state
                # ==========================================

                if (-not $Result) {

                    try {

                        $GroupsAfter = Get-MgUserMemberOf `
                            -UserId $User.Id `
                            -All

                        # Verify target role is present
                        $NewAccess = $GroupsAfter |
                            Where-Object {
                                $_.AdditionalProperties.displayName -eq $TargetGroupName
                            }

                        # Verify no obsolete managed job-role groups remain
                        $OldAccess = $GroupsAfter |
                            Where-Object {
                                $_.AdditionalProperties.displayName -in $ManagedRBACGroups -and
                                $_.AdditionalProperties.displayName -ne $TargetGroupName
                            }

                        if ($NewAccess -and -not $OldAccess) {

                            Write-Host ""
                            Write-Host "Result: MOVER SUCCESSFUL"
                            Write-Host "Verification: SUCCESS"

                            $Result = "Mover Successful"
                            $Verification = "Verified - Obsolete RBAC Removed / Target RBAC Present"
                        }
                        else {

                            Write-Host ""
                            Write-Host "Result: MOVER VERIFICATION FAILED"
                            Write-Host "Verification: FAILED"

                            $Result = "Mover Verification Failed"
                            $Verification = "Managed RBAC State Incorrect"
                        }
                    }
                    catch {

                        Write-Host ""
                        Write-Host "Result: MOVER VERIFICATION FAILED"
                        Write-Host "Details: $($_.Exception.Message)"

                        $Result = "Mover Verification Failed"
                        $Verification = "Graph Verification Query Failed"
                    }
                }
            }
        }

        Write-Host "--------------------------------------"

        # ==========================================
        # Generate audit evidence
        # ==========================================

        $AuditResults += [PSCustomObject]@{
            "Employee ID"     = $Request."Employee ID"
            "User"            = $Request.User
            "Old RBAC Group"  = $OldGroupName
            "New Department"  = $Request.Department
            "New Job Title"   = $Request."Job Title"
            "New RBAC Group"  = $TargetGroupName
            "Lifecycle Event" = $Request."LifeCycle Event"
            "Effective Date"  = $Request."Effective Date"
            "Action Date"     = (Get-Date).ToString("MM/dd/yyyy")
            "Result"          = $Result
            "Verification"    = $Verification
        }
    }
}

# ==========================================
# Export audit evidence
# ==========================================

try {

    $AuditResults |
        Export-Csv $MoverAuditFile -NoTypeInformation
}
catch {

    Write-Error "Unable to export Mover audit evidence: $($_.Exception.Message)"
    exit 1
}

Write-Host ""
Write-Host "======================================"
Write-Host "MOVER AUDIT EVIDENCE CREATED"
Write-Host "======================================"
Write-Host $MoverAuditFile
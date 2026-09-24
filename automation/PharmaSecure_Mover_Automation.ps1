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

# Role-to-group mapping
$RBACMapping = @{
    "Laboratory|Lab Analyst"               = "IAM-RBAC-Lab-Analysts"
    "Quality|QA Specialist"                = "IAM-RBAC-QA"
    "R&D|Research Scientist"               = "IAM-RBAC-RD-Scientists"
    "Manufacturing|Manufacturing Operator" = "IAM-RBAC-Manufacturing"
    "HR|HR Specialist"                     = "IAM-RBAC-HR"
    "IT|Systems Administrator"             = "IAM-RBAC-IT-Admins"
}

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
        $OldGroupId = $null
        $User = $null
        $TargetGroup = $null

        Write-Host "Employee ID: $($Request.'Employee ID')"
        Write-Host "User: $($Request.User)"
        Write-Host "New Department: $($Request.Department)"
        Write-Host "New Job Title: $($Request.'Job Title')"
        Write-Host ""

        # Determine target RBAC group
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

            # ------------------------------------------
            # Graph discovery
            # ------------------------------------------

            try {
                $User = Get-MgUser `
                    -Filter "displayName eq '$($Request.User)'"

                if (-not $User) {
                    throw "User '$($Request.User)' was not found in Microsoft Entra ID."
                }

                # Get current RBAC memberships
                $CurrentGroups = Get-MgUserMemberOf `
                    -UserId $User.Id `
                    -All

                $CurrentRBACGroups = $CurrentGroups |
                    Where-Object {
                        $_.AdditionalProperties.displayName -like "IAM-RBAC-*"
                    }

                # Determine existing RBAC group that differs
                # from the requested target group
                $OldGroup = $CurrentRBACGroups |
                    Where-Object {
                        $_.AdditionalProperties.displayName -ne $TargetGroupName
                    } |
                    Select-Object -First 1

                if ($OldGroup) {
                    $OldGroupName = $OldGroup.AdditionalProperties.displayName
                    $OldGroupId = $OldGroup.Id
                }
                else {
                    $OldGroupName = "None"
                    $OldGroupId = $null
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

                Write-Host "Current RBAC Group: $OldGroupName"
                Write-Host "Target RBAC Group: $TargetGroupName"
                Write-Host ""

                # ------------------------------------------
                # Remove obsolete RBAC membership
                # ------------------------------------------

                if ($OldGroupId) {

                    Write-Host "Action: Removing old RBAC membership"

                    try {
                        Remove-MgGroupMemberByRef `
                            -GroupId $OldGroupId `
                            -DirectoryObjectId $User.Id

                        Write-Host "Old RBAC membership removed"
                    }
                    catch {

                        Write-Host "Result: MOVER FAILED"
                        Write-Host "Details: Failed to remove old RBAC membership."
                        Write-Host "Graph Error: $($_.Exception.Message)"

                        $Result = "Mover Failed - Old RBAC Removal"
                        $Verification = "Graph Removal Operation Failed"
                    }
                }

                # ------------------------------------------
                # Add target RBAC membership
                # ------------------------------------------

                if (-not $Result) {

                    # Check whether target membership already exists
                    $ExistingTargetAccess = $CurrentRBACGroups |
                        Where-Object {
                            $_.AdditionalProperties.displayName -eq $TargetGroupName
                        }

                    if ($ExistingTargetAccess) {

                        Write-Host "Target RBAC Access: ALREADY PRESENT"
                        Write-Host "Action: No duplicate assignment required"
                    }
                    else {

                        Write-Host "Action: Adding new RBAC membership"

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

                # ------------------------------------------
                # Verify final access state
                # ------------------------------------------

                if (-not $Result) {

                    try {
                        $GroupsAfter = Get-MgUserMemberOf `
                            -UserId $User.Id `
                            -All

                        $NewAccess = $GroupsAfter |
                            Where-Object {
                                $_.AdditionalProperties.displayName -eq $TargetGroupName
                            }

                        $OldAccess = $null

                        if ($OldGroupId) {
                            $OldAccess = $GroupsAfter |
                                Where-Object {
                                    $_.Id -eq $OldGroupId
                                }
                        }

                        if ($NewAccess -and -not $OldAccess) {

                            Write-Host ""
                            Write-Host "Result: MOVER SUCCESSFUL"
                            Write-Host "Verification: SUCCESS"

                            $Result = "Mover Successful"
                            $Verification = "Verified - Old RBAC Removed / New RBAC Present"
                        }
                        else {

                            Write-Host ""
                            Write-Host "Result: MOVER VERIFICATION FAILED"
                            Write-Host "Verification: FAILED"

                            $Result = "Mover Verification Failed"
                            $Verification = "Old or New RBAC State Incorrect"
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

        # Generate audit record
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

# Export audit evidence
try {
    $AuditResults | Export-Csv $MoverAuditFile -NoTypeInformation
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
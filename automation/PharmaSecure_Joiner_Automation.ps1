# ==========================================
# PharmaSecure IAM - Joiner Automation
# Fictional pharmaceutical IAM laboratory
# Purpose: Provision role-based access for Joiner requests
# ==========================================

# Force terminating errors so Graph failures can be caught
$ErrorActionPreference = "Stop"

# Determine project root from script location
$ProjectRoot = Split-Path $PSScriptRoot -Parent

# Portable project paths
$JMLFile = Join-Path $ProjectRoot "evidence\PharmaSecure_JML_Register.csv"
$JMLAuditFile = Join-Path $ProjectRoot "evidence\PharmaSecure_JML_Audit_Evidence.csv"

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
Write-Host "PHARMASECURE JML JOINER AUTOMATION"
Write-Host "======================================"
Write-Host ""

foreach ($Request in $JMLRegister) {

    if ($Request.Status -eq "Pending" -and
        $Request."LifeCycle Event" -eq "Joiner") {

        # Reset variables for each request
        $Result = $null
        $Verification = $null
        $TargetGroupName = $null

        Write-Host "Employee ID: $($Request.'Employee ID')"
        Write-Host "User: $($Request.User)"
        Write-Host "Department: $($Request.Department)"
        Write-Host "Job Title: $($Request.'Job Title')"
        Write-Host "Lifecycle Event: $($Request.'LifeCycle Event')"
        Write-Host ""

        # Determine appropriate RBAC group
        $MappingKey = "$($Request.Department)|$($Request.'Job Title')"
        $TargetGroupName = $RBACMapping[$MappingKey]

        Write-Host "Target RBAC Group: $TargetGroupName"

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

                $TargetGroup = Get-MgGroup `
                    -Filter "displayName eq '$TargetGroupName'"

                if (-not $TargetGroup) {
                    throw "Target RBAC group '$TargetGroupName' was not found."
                }

                $Members = Get-MgGroupMember `
                    -GroupId $TargetGroup.Id `
                    -All

                $ExistingAccess = $Members |
                    Where-Object { $_.Id -eq $User.Id }
            }
            catch {

                Write-Host ""
                Write-Host "Result: FAILED - Microsoft Graph lookup error"
                Write-Host "Details: $($_.Exception.Message)"
                Write-Host "Action: No access change performed"

                $Result = "Failed - Graph Lookup Error"
                $Verification = "Not Performed"
            }

            # Continue only if discovery succeeded
            if (-not $Result) {

                if ($ExistingAccess) {

                    Write-Host "Entra Access: PRESENT"
                    Write-Host "Action: NO ACTION REQUIRED"

                    $Result = "Already Provisioned"
                    $Verification = "Verified - User Already In Required RBAC Group"
                }
                else {

                    Write-Host "Entra Access: NOT PRESENT"
                    Write-Host "Action: PROVISIONING RBAC ACCESS"

                    # ------------------------------------------
                    # Provision access
                    # ------------------------------------------

                    try {
                        New-MgGroupMemberByRef `
                            -GroupId $TargetGroup.Id `
                            -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($User.Id)"
                    }
                    catch {

                        Write-Host "Result: JOINER PROVISIONING FAILED"
                        Write-Host "Details: $($_.Exception.Message)"

                        $Result = "Joiner Provisioning Failed"
                        $Verification = "Graph Provisioning Operation Failed"
                    }

                    # ------------------------------------------
                    # Verify access
                    # ------------------------------------------

                    if (-not $Result) {

                        try {
                            $MembersAfter = Get-MgGroupMember `
                                -GroupId $TargetGroup.Id `
                                -All

                            $AccessAfter = $MembersAfter |
                                Where-Object { $_.Id -eq $User.Id }

                            if ($AccessAfter) {

                                Write-Host "Result: JOINER PROVISIONING SUCCESSFUL"
                                Write-Host "Verification: SUCCESS"

                                $Result = "Joiner Provisioning Successful"
                                $Verification = "Verified - User Added To Required RBAC Group"
                            }
                            else {

                                Write-Host "Result: JOINER VERIFICATION FAILED"
                                Write-Host "Verification: FAILED"

                                $Result = "Joiner Verification Failed"
                                $Verification = "User Not Found In Required RBAC Group"
                            }
                        }
                        catch {

                            Write-Host "Result: JOINER VERIFICATION FAILED"
                            Write-Host "Details: $($_.Exception.Message)"

                            $Result = "Joiner Verification Failed"
                            $Verification = "Graph Verification Query Failed"
                        }
                    }
                }
            }
        }

        Write-Host "--------------------------------------"

        # Generate audit record
        $AuditResults += [PSCustomObject]@{
            "Employee ID"     = $Request."Employee ID"
            "User"            = $Request.User
            "Department"      = $Request.Department
            "Job Title"       = $Request."Job Title"
            "RBAC Group"      = $TargetGroupName
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
    $AuditResults | Export-Csv $JMLAuditFile -NoTypeInformation
}
catch {
    Write-Error "Unable to export JML audit evidence: $($_.Exception.Message)"
    exit 1
}

Write-Host ""
Write-Host "======================================"
Write-Host "JML AUDIT EVIDENCE CREATED"
Write-Host "======================================"
Write-Host $JMLAuditFile
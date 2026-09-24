# ==========================================
# PharmaSecure IAM - Mover Automation
# Fictional pharmaceutical IAM laboratory
# ==========================================
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
$JMLRegister = Import-Csv $JMLFile
$RBACMapping = @{
    "Laboratory|Lab Analyst" = "IAM-RBAC-Lab-Analysts"
    "Quality|QA Specialist" = "IAM-RBAC-QA"
    "R&D|Research Scientist" = "IAM-RBAC-RD-Scientists"
    "Manufacturing|Manufacturing Operator" = "IAM-RBAC-Manufacturing"
    "HR|HR Specialist" = "IAM-RBAC-HR"
    "IT|Systems Administrator" = "IAM-RBAC-IT-Admins"
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

        Write-Host "Employee ID: $($Request."Employee ID")"
        Write-Host "User: $($Request.User)"
        Write-Host "New Department: $($Request.Department)"
        Write-Host "New Job Title: $($Request."Job Title")"
        Write-Host ""

        # Determine target RBAC group
        $MappingKey = "$($Request.Department)|$($Request."Job Title")"
        $TargetGroupName = $RBACMapping[$MappingKey]

        Write-Host "Target RBAC Group: $TargetGroupName"
        Write-Host ""

        if (-not $TargetGroupName) {

            Write-Host "Result: FAILED - No RBAC mapping found"

            $Result = "Failed - No RBAC Mapping"
            $Verification = "Not Performed"
            $OldGroupName = "Unknown"

        }
        else {

            # Find user
            $User = Get-MgUser -Filter "displayName eq '$($Request.User)'"

            if (-not $User) {

                Write-Host "Result: FAILED - User not found in Entra"

                $Result = "Failed - User Not Found"
                $Verification = "Not Performed"
                $OldGroupName = "Unknown"

            }
            else {

                # Get current RBAC memberships
                $CurrentGroups = Get-MgUserMemberOf -UserId $User.Id -All

                $CurrentRBACGroups = $CurrentGroups |
                    Where-Object {
                        $_.AdditionalProperties.displayName -like "IAM-RBAC-*"
                    }

                # Determine old RBAC group
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

                Write-Host "Current RBAC Group: $OldGroupName"
                Write-Host "Target RBAC Group: $TargetGroupName"
                Write-Host ""

                # Find target group
                $TargetGroup = Get-MgGroup -Filter "displayName eq '$TargetGroupName'"

                if (-not $TargetGroup) {

                    Write-Host "Result: FAILED - Target RBAC group not found"

                    $Result = "Failed - Target Group Not Found"
                    $Verification = "Not Performed"

                }
                else {

                    # Remove old RBAC membership
                    if ($OldGroupId) {

                        Write-Host "Action: Removing old RBAC membership"

                        Remove-MgGroupMemberByRef `
                            -GroupId $OldGroupId `
                            -DirectoryObjectId $User.Id

                        Write-Host "Old RBAC membership removed"
                    }

                    # Add new RBAC membership
                    Write-Host "Action: Adding new RBAC membership"

                    New-MgGroupMemberByRef `
                        -GroupId $TargetGroup.Id `
                        -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($User.Id)"

                    # Verify new membership
                    $GroupsAfter = Get-MgUserMemberOf -UserId $User.Id -All

                    $NewAccess = $GroupsAfter |
                        Where-Object {
                            $_.AdditionalProperties.displayName -eq $TargetGroupName
                        }

                    # Verify old membership removed
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
            }
        }

        Write-Host "--------------------------------------"

        $AuditResults += [PSCustomObject]@{
            "Employee ID"       = $Request."Employee ID"
            "User"              = $Request.User
            "Old RBAC Group"    = $OldGroupName
            "New Department"    = $Request.Department
            "New Job Title"     = $Request."Job Title"
            "New RBAC Group"    = $TargetGroupName
            "Lifecycle Event"   = $Request."LifeCycle Event"
            "Effective Date"    = $Request."Effective Date"
            "Action Date"       = (Get-Date).ToString("MM/dd/yyyy")
            "Result"            = $Result
            "Verification"      = $Verification
        }
    }
}

$AuditResults | Export-Csv $MoverAuditFile -NoTypeInformation

Write-Host ""
Write-Host "======================================"
Write-Host "MOVER AUDIT EVIDENCE CREATED"
Write-Host "======================================"
Write-Host $MoverAuditFile
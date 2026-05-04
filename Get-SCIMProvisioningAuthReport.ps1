<#
.SYNOPSIS
    Identifies SCIM provisioning applications using OAuth 2.0 Authorization Code grant.
.DESCRIPTION
    Scans all service principals in the tenant for active SCIM provisioning jobs
    and reports which ones use OAuth 2.0 Authorization Code grant authentication.
    These apps must be migrated to modern authentication (e.g., Client Credentials flow).
.NOTES
    Requires: Microsoft.Graph.Entra module (Install-Module Microsoft.Graph.Entra)
    Permissions: Application.Read.All, Synchronization.Read.All
.LINK
    https://learn.microsoft.com/en-us/entra/fundamentals/whats-new#plan-for-change---update-scim-provisioning-applications-to-use-modern-authentication
#>

#Requires -Modules Microsoft.Graph.Entra

# --- Connect to Microsoft Entra ---
Write-Host "`n=== SCIM Provisioning Auth Method Scanner ===" -ForegroundColor Cyan
Write-Host "Connecting to Microsoft Entra..." -ForegroundColor Yellow

Connect-Entra -Scopes "Application.Read.All", "Synchronization.Read.All"

# --- Get all service principals ---
Write-Host "Fetching service principals with provisioning support..." -ForegroundColor Yellow

$allSPs = Get-EntraServicePrincipal -All
$scimApps = @()
$oauthCodeApps = @()
$otherAuthApps = @()
$errorApps = @()
$processedCount = 0

Write-Host "Found $($allSPs.Count) total service principals. Scanning for SCIM provisioning jobs...`n" -ForegroundColor Yellow

foreach ($sp in $allSPs) {
    $processedCount++
    if ($processedCount % 50 -eq 0) {
        Write-Host "  Processed $processedCount / $($allSPs.Count) service principals..." -ForegroundColor Gray
    }

    try {
        # Check if this SP has synchronization jobs (SCIM provisioning)
        $syncJobs = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.Id)/synchronization/jobs" `
            -ErrorAction SilentlyContinue

        if (-not $syncJobs -or -not $syncJobs.value -or $syncJobs.value.Count -eq 0) {
            continue
        }

        # This SP has provisioning jobs
        $appInfo = [PSCustomObject]@{
            DisplayName      = $sp.DisplayName
            AppId            = $sp.AppId
            ObjectId         = $sp.Id
            JobCount         = $syncJobs.value.Count
            JobStatus        = ($syncJobs.value | ForEach-Object { $_.status.code }) -join ", "
            AuthMethod       = "Unknown"
        }

        # Check synchronization secrets for auth type
        try {
            $secrets = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.Id)/synchronization/secrets" `
                -ErrorAction SilentlyContinue

            $authType = "Unknown"
            if ($secrets -and $secrets.value) {
                foreach ($secret in $secrets.value) {
                    if ($secret.key -eq "AuthenticationType") {
                        $authType = $secret.value
                        break
                    }
                }

                # If no explicit AuthenticationType, check for OAuth2 credential keys
                if ($authType -eq "Unknown") {
                    $secretKeys = $secrets.value | ForEach-Object { $_.key }
                    if ($secretKeys -contains "AuthorizationCode" -or 
                        $secretKeys -contains "RedirectUri") {
                        $authType = "OAuth2AuthCodeGrant (inferred)"
                    }
                    elseif ($secretKeys -contains "ClientSecret" -and 
                            $secretKeys -contains "ClientId" -and 
                            $secretKeys -notcontains "AuthorizationCode") {
                        $authType = "OAuth2ClientCredentials (inferred)"
                    }
                    elseif ($secretKeys -contains "SecretToken") {
                        $authType = "BearerToken"
                    }
                }
            }

            $appInfo.AuthMethod = $authType

        } catch {
            $appInfo.AuthMethod = "Unable to read secrets"
        }

        $scimApps += $appInfo

        if ($appInfo.AuthMethod -match "AuthCodeGrant|AuthorizationCode") {
            $oauthCodeApps += $appInfo
        } else {
            $otherAuthApps += $appInfo
        }

    } catch {
        # No sync jobs or access denied - skip
        continue
    }
}

# --- Output Results ---
Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "           SCAN RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

Write-Host "`nTotal Service Principals Scanned : $($allSPs.Count)" -ForegroundColor White
Write-Host "SCIM Provisioning Apps Found     : $($scimApps.Count)" -ForegroundColor White

Write-Host "`n--- All SCIM Provisioning Applications ---" -ForegroundColor Green
if ($scimApps.Count -gt 0) {
    $scimApps | Format-Table DisplayName, AppId, JobStatus, AuthMethod -AutoSize -Wrap
} else {
    Write-Host "  No SCIM provisioning applications found." -ForegroundColor Gray
}

Write-Host "=============================================" -ForegroundColor Red
Write-Host " ACTION REQUIRED: OAuth 2.0 Authorization Code Grant Apps" -ForegroundColor Red
Write-Host "=============================================" -ForegroundColor Red

if ($oauthCodeApps.Count -gt 0) {
    Write-Host "`nFound $($oauthCodeApps.Count) app(s) using OAuth 2.0 Authorization Code grant:" -ForegroundColor Red
    $oauthCodeApps | Format-Table DisplayName, AppId, ObjectId, AuthMethod -AutoSize -Wrap
    Write-Host "These apps must be migrated to OAuth 2.0 Client Credentials flow." -ForegroundColor Yellow
    Write-Host "See: https://learn.microsoft.com/en-us/entra/fundamentals/whats-new#plan-for-change---update-scim-provisioning-applications-to-use-modern-authentication" -ForegroundColor Yellow
} else {
    Write-Host "`n  No apps found using OAuth 2.0 Authorization Code grant." -ForegroundColor Green
    Write-Host "  Your SCIM provisioning apps appear to be using modern authentication." -ForegroundColor Green
}

Write-Host "`n--- Apps Using Other Auth Methods ---" -ForegroundColor Green
if ($otherAuthApps.Count -gt 0) {
    $otherAuthApps | Format-Table DisplayName, AuthMethod -AutoSize -Wrap
}

# --- Export to CSV ---
$csvPath = "$env:USERPROFILE\Desktop\SCIM_Provisioning_AuthMethod_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$scimApps | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "`nReport exported to: $csvPath" -ForegroundColor Cyan
Write-Host "`nDone!`n" -ForegroundColor Green

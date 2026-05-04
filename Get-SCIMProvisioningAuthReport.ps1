<#
.SYNOPSIS
    Identifies SCIM provisioning applications using OAuth 2.0 Authorization Code grant.
.DESCRIPTION
    Scans service principals in the tenant for SCIM provisioning jobs that use
    OAuth 2.0 Authorization Code grant authentication. These apps must be migrated
    to modern authentication (e.g., Client Credentials flow).
    
    Optimized: Uses known run-profile tags of apps that support Code Auth Grant flow.
    Only checks SPs with matching sync job templates, dramatically reducing API calls.
.NOTES
    Requires: Microsoft.Graph.Applications module (Install-Module Microsoft.Graph.Applications)
    Permissions: Application.Read.All, Synchronization.Read.All
.LINK
    https://learn.microsoft.com/en-us/entra/fundamentals/whats-new#plan-for-change---update-scim-provisioning-applications-to-use-modern-authentication
#>

#Requires -Modules Microsoft.Graph.Applications

# --- Known run-profile tags for apps that support OAuth 2.0 Authorization Code Grant in SCIM ---
$codeAuthGrantRunProfiles = @(
    "GoogV2OutDelta"
    "zoom"
    "slackOutDelta"
    "GitHubOutDelta"
    "BoxOutDelta"
    "DropboxSCIMOutDelta"
    "ringCentral"
    "travelPerk"
    "amazonbusiness"
    "facebookWorkAccounts"
    "vonage"
    "zohoOne"
    "uber"
    "gong"
    "logMeIn"
    "bPanda"
    "atea"
    "secureLogin"
    "puzzel"
    "chatWork"
    "swit"
    "taskizeConnect"
    "contentstack"
    "gotomeeting"
    "facebookWorkplace"
)

# Friendly display names for the run-profile tags
$runProfileDisplayNames = @{
    "GoogV2OutDelta"        = "Google Workspace"
    "zoom"                  = "Zoom"
    "slackOutDelta"         = "Slack"
    "GitHubOutDelta"        = "GitHub"
    "BoxOutDelta"           = "Box"
    "DropboxSCIMOutDelta"   = "Dropbox"
    "ringCentral"           = "RingCentral"
    "travelPerk"            = "TravelPerk"
    "amazonbusiness"        = "Amazon Business"
    "facebookWorkAccounts"  = "Facebook Work Accounts"
    "vonage"                = "Vonage"
    "zohoOne"               = "Zoho One"
    "uber"                  = "Uber"
    "gong"                  = "Gong"
    "logMeIn"               = "LogMeIn"
    "bPanda"                = "BPanda"
    "atea"                  = "Atea"
    "secureLogin"           = "SecureLogin"
    "puzzel"                = "Puzzel"
    "chatWork"              = "ChatWork"
    "swit"                  = "Swit"
    "taskizeConnect"        = "Taskize Connect"
    "contentstack"          = "Contentstack"
    "gotomeeting"           = "GoToMeeting"
    "facebookWorkplace"     = "Facebook Workplace"
}

# --- Connect to Microsoft Graph ---
Write-Host "`n=== SCIM Provisioning - OAuth 2.0 Code Auth Grant Scanner ===" -ForegroundColor Cyan
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow

Connect-MgGraph -Scopes "Application.Read.All", "Synchronization.Read.All" -NoWelcome

# --- List known Code Auth Grant app templates ---
Write-Host "`n--- Applications that support OAuth 2.0 Authorization Code Grant in SCIM ---" -ForegroundColor Yellow
Write-Host "Total known app templates: $($codeAuthGrantRunProfiles.Count)`n" -ForegroundColor White
foreach ($tag in $codeAuthGrantRunProfiles) {
    $friendly = if ($runProfileDisplayNames.ContainsKey($tag)) { $runProfileDisplayNames[$tag] } else { $tag }
    Write-Host "  - $friendly ($tag)" -ForegroundColor Gray
}

# --- Get all service principals with provisioning (gallery apps) ---
Write-Host "`nFetching gallery service principals..." -ForegroundColor Yellow
$gallerySPs = Get-MgServicePrincipal -All `
    -Filter "tags/any(t: t eq 'WindowsAzureActiveDirectoryGalleryApplicationNonPrimaryV1')" `
    -Property Id, DisplayName, AppId, Tags, ServicePrincipalType

Write-Host "Found $($gallerySPs.Count) gallery service principals. Checking for SCIM provisioning jobs...`n" -ForegroundColor Yellow

# --- Scan SPs for sync jobs matching Code Auth Grant run profiles ---
$scimApps = @()
$codeAuthGrantApps = @()
$otherAuthApps = @()
$processedCount = 0

# Helper: Send Graph batch requests (up to 20 per batch)
function Invoke-GraphBatch {
    param([array]$Requests)
    $batchBody = @{ requests = $Requests } | ConvertTo-Json -Depth 10
    $result = Invoke-MgGraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/`$batch" `
        -Body $batchBody -ContentType "application/json"
    return $result.responses
}

$spArray = @($gallerySPs)
$batchSize = 20

for ($i = 0; $i -lt $spArray.Count; $i += $batchSize) {
    $batch = $spArray[$i..([Math]::Min($i + $batchSize - 1, $spArray.Count - 1))]
    $requests = @()

    foreach ($sp in $batch) {
        $requests += @{
            id     = $sp.Id
            method = "GET"
            url    = "/servicePrincipals/$($sp.Id)/synchronization/jobs"
        }
    }

    try {
        $responses = Invoke-GraphBatch -Requests $requests

        foreach ($resp in $responses) {
            if ($resp.status -eq 200 -and $resp.body.value -and $resp.body.value.Count -gt 0) {
                $matchingSP = $batch | Where-Object { $_.Id -eq $resp.id } | Select-Object -First 1
                if (-not $matchingSP) { continue }

                foreach ($job in $resp.body.value) {
                    $templateId = $job.templateId
                    $isCodeAuthGrant = $codeAuthGrantRunProfiles -contains $templateId

                    $appInfo = [PSCustomObject]@{
                        DisplayName     = $matchingSP.DisplayName
                        AppId           = $matchingSP.AppId
                        ObjectId        = $matchingSP.Id
                        TemplateId      = $templateId
                        AppTemplate     = if ($runProfileDisplayNames.ContainsKey($templateId)) { $runProfileDisplayNames[$templateId] } else { $templateId }
                        JobStatus       = $job.status.code
                        AuthType        = if ($isCodeAuthGrant) { "OAuth2 Authorization Code Grant" } else { "Other (Bearer Token / Client Credentials)" }
                        IsCodeAuthGrant = $isCodeAuthGrant
                    }

                    $scimApps += $appInfo
                    if ($isCodeAuthGrant) {
                        $codeAuthGrantApps += $appInfo
                    } else {
                        $otherAuthApps += $appInfo
                    }
                }
            }
        }
    } catch {
        # Fallback: try individual requests for this batch
        foreach ($sp in $batch) {
            try {
                $syncJobs = Invoke-MgGraphRequest -Method GET `
                    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.Id)/synchronization/jobs" `
                    -ErrorAction SilentlyContinue
                if ($syncJobs -and $syncJobs.value -and $syncJobs.value.Count -gt 0) {
                    foreach ($job in $syncJobs.value) {
                        $templateId = $job.templateId
                        $isCodeAuthGrant = $codeAuthGrantRunProfiles -contains $templateId
                        $appInfo = [PSCustomObject]@{
                            DisplayName     = $sp.DisplayName
                            AppId           = $sp.AppId
                            ObjectId        = $sp.Id
                            TemplateId      = $templateId
                            AppTemplate     = if ($runProfileDisplayNames.ContainsKey($templateId)) { $runProfileDisplayNames[$templateId] } else { $templateId }
                            JobStatus       = $job.status.code
                            AuthType        = if ($isCodeAuthGrant) { "OAuth2 Authorization Code Grant" } else { "Other (Bearer Token / Client Credentials)" }
                            IsCodeAuthGrant = $isCodeAuthGrant
                        }
                        $scimApps += $appInfo
                        if ($isCodeAuthGrant) { $codeAuthGrantApps += $appInfo }
                        else { $otherAuthApps += $appInfo }
                    }
                }
            } catch { continue }
        }
    }

    $processedCount += $batch.Count
    if ($processedCount % 100 -eq 0 -or $processedCount -ge $spArray.Count) {
        Write-Host "  Checked $processedCount / $($spArray.Count) SPs... (Found $($scimApps.Count) SCIM jobs, $($codeAuthGrantApps.Count) using Code Auth Grant)" -ForegroundColor Gray
    }
}

# --- Output Results ---
Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "           SCAN RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

Write-Host "`nTotal Gallery SPs Scanned            : $($gallerySPs.Count)" -ForegroundColor White
Write-Host "Total SCIM Provisioning Jobs Found   : $($scimApps.Count)" -ForegroundColor White
Write-Host "Code Auth Grant Apps (Action Needed)  : $($codeAuthGrantApps.Count)" -ForegroundColor $(if ($codeAuthGrantApps.Count -gt 0) { "Red" } else { "Green" })
Write-Host "Other Auth Method Apps (No Action)    : $($otherAuthApps.Count)" -ForegroundColor Green

Write-Host "`n--- All SCIM Provisioning Applications ---" -ForegroundColor Green
if ($scimApps.Count -gt 0) {
    $scimApps | Format-Table DisplayName, AppTemplate, TemplateId, JobStatus, AuthType -AutoSize -Wrap
} else {
    Write-Host "  No SCIM provisioning applications found." -ForegroundColor Gray
}

Write-Host "=============================================" -ForegroundColor Red
Write-Host " ACTION REQUIRED: OAuth 2.0 Authorization Code Grant Apps" -ForegroundColor Red
Write-Host "=============================================" -ForegroundColor Red

if ($codeAuthGrantApps.Count -gt 0) {
    Write-Host "`nFound $($codeAuthGrantApps.Count) app(s) using OAuth 2.0 Authorization Code Grant:" -ForegroundColor Red
    $codeAuthGrantApps | Format-Table DisplayName, AppId, ObjectId, AppTemplate, JobStatus -AutoSize -Wrap
    Write-Host "`nThese apps MUST be migrated to OAuth 2.0 Client Credentials flow before the deprecation deadline." -ForegroundColor Yellow
    Write-Host "See: https://learn.microsoft.com/en-us/entra/fundamentals/whats-new#plan-for-change---update-scim-provisioning-applications-to-use-modern-authentication`n" -ForegroundColor Yellow
} else {
    Write-Host "`n  No apps found using OAuth 2.0 Authorization Code Grant." -ForegroundColor Green
    Write-Host "  Your SCIM provisioning apps appear to be using modern authentication.`n" -ForegroundColor Green
}

if ($otherAuthApps.Count -gt 0) {
    Write-Host "--- Apps Using Other Auth Methods (No Action Needed) ---" -ForegroundColor Green
    $otherAuthApps | Format-Table DisplayName, AppTemplate, AuthType -AutoSize -Wrap
}

# --- Export to CSV ---
$csvPath = "$env:USERPROFILE\Desktop\SCIM_Provisioning_AuthMethod_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$scimApps | Select-Object DisplayName, AppId, ObjectId, TemplateId, AppTemplate, JobStatus, AuthType, IsCodeAuthGrant `
    | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "Report exported to: $csvPath" -ForegroundColor Cyan
Write-Host "`nDone!`n" -ForegroundColor Green

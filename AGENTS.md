# Agent Lead Instructions: SCIM Provisioning — Code Auth Grant Deprecation Scanner

## Overview

Microsoft Entra ID is deprecating **OAuth 2.0 Authorization Code Grant** for SCIM (System for Cross-domain Identity Management) provisioning applications. Organizations must identify affected apps and migrate them to **OAuth 2.0 Client Credentials** flow before the deprecation deadline.

This repository contains a PowerShell scanner script (`Get-SCIMProvisioningAuthReport.ps1`) that automates the detection of SCIM provisioning apps in your Entra ID tenant that still use the deprecated Authorization Code Grant flow.

> **Reference**: [Plan for change — Update SCIM provisioning applications to use modern authentication](https://learn.microsoft.com/en-us/entra/fundamentals/whats-new#plan-for-change---update-scim-provisioning-applications-to-use-modern-authentication)

---

## What Is the Problem?

SCIM provisioning in Entra ID supports two OAuth 2.0 authentication methods for connecting to third-party SaaS applications:

| Auth Method | Status | Description |
|-------------|--------|-------------|
| **Authorization Code Grant** | ⚠️ **Deprecated** | User-delegated flow requiring interactive consent. Being phased out for SCIM provisioning. |
| **Client Credentials Grant** | ✅ **Recommended** | Application-level flow using client ID/secret. No user interaction required. |

Apps using Authorization Code Grant will **stop working** after the deprecation date. Affected apps must be re-authorized using Client Credentials flow.

---

## Which Applications Are Affected?

The scanner identifies apps based on their **sync job template ID** (run-profile tag). The following 25 gallery applications support OAuth 2.0 Authorization Code Grant for SCIM provisioning:

| Application | Run-Profile Tag |
|-------------|----------------|
| Google Workspace | `GoogV2OutDelta` |
| Zoom | `zoom` |
| Slack | `slackOutDelta` |
| GitHub | `GitHubOutDelta` |
| Box | `BoxOutDelta` |
| Dropbox | `DropboxSCIMOutDelta` |
| RingCentral | `ringCentral` |
| TravelPerk | `travelPerk` |
| Amazon Business | `amazonbusiness` |
| Facebook Work Accounts | `facebookWorkAccounts` |
| Vonage | `vonage` |
| Zoho One | `zohoOne` |
| Uber | `uber` |
| Gong | `gong` |
| LogMeIn | `logMeIn` |
| BPanda | `bPanda` |
| Atea | `atea` |
| SecureLogin | `secureLogin` |
| Puzzel | `puzzel` |
| ChatWork | `chatWork` |
| Swit | `swit` |
| Taskize Connect | `taskizeConnect` |
| Contentstack | `contentstack` |
| GoToMeeting | `gotomeeting` |
| Facebook Workplace | `facebookWorkplace` |

> **Note**: If a SCIM provisioning app uses a template ID that is NOT in this list, it uses Bearer Token or Client Credentials and requires **no action**.

---

## Prerequisites

### 1. PowerShell Module

Install the Microsoft Graph PowerShell module:

```powershell
Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force
```

### 2. Entra ID Permissions

The scanning account or service principal needs the following **Microsoft Graph** permissions:

| Permission | Type | Purpose |
|-----------|------|---------|
| `Application.Read.All` | Delegated or Application | Read service principal metadata and tags |
| `Synchronization.Read.All` | Delegated or Application | Read synchronization jobs and template IDs |

### 3. Tenant Access

- You must have access to the target Entra ID tenant
- Global Reader, Application Administrator, or Cloud Application Administrator role is sufficient
- For multi-tenant scenarios, run the script in each tenant separately

---

## How to Run the Scanner

### Step 1: Open PowerShell

Open a PowerShell 7+ terminal (or Windows PowerShell 5.1).

### Step 2: Navigate to the Script Directory

```powershell
cd C:\path\to\SCIM-CodeAuthGrantDeprecation
```

### Step 3: Execute the Script

```powershell
.\Get-SCIMProvisioningAuthReport.ps1
```

### Step 4: Authenticate

A browser window will open for interactive sign-in to Microsoft Graph. Sign in with an account that has the required permissions.

### Step 5: Review Results

The script will:
1. Fetch all gallery service principals in the tenant
2. Use **batch Graph API calls** (20 per batch) for performance
3. Check each SP's synchronization jobs against the known Code Auth Grant template list
4. Display a color-coded summary in the terminal
5. Export a detailed CSV report to the current directory

---

## Understanding the Output

### Terminal Output

```
=== SCIM Provisioning - OAuth 2.0 Code Auth Grant Scanner ===

Total Gallery SPs Scanned            : 245
Total SCIM Provisioning Jobs Found   : 12
Code Auth Grant Apps (Action Needed)  : 3    ← RED if > 0
Other Auth Method Apps (No Action)    : 9    ← GREEN
```

### Action Required Section

Apps listed under **"ACTION REQUIRED"** (in red) are using the deprecated Authorization Code Grant and must be migrated.

### CSV Report

The script generates a timestamped CSV file:

```
SCIM_Provisioning_AuthMethod_Report_20260509_192345.csv
```

CSV columns:

| Column | Description |
|--------|-------------|
| `DisplayName` | Service principal display name in Entra ID |
| `AppId` | Application (client) ID |
| `ObjectId` | Service principal object ID |
| `TemplateId` | Sync job template/run-profile tag |
| `AppTemplate` | Friendly application name |
| `JobStatus` | Current provisioning job status (e.g., `Active`, `Quarantine`) |
| `AuthType` | `OAuth2 Authorization Code Grant` or `Other (Bearer Token / Client Credentials)` |
| `IsCodeAuthGrant` | `TRUE` if the app uses the deprecated flow |

---

## How the Scanner Works

### Detection Logic

The scanner uses an **optimized detection approach** based on known run-profile tags rather than inspecting credential metadata:

1. **Fetch Gallery SPs** — Queries all service principals tagged with `WindowsAzureActiveDirectoryGalleryApplicationNonPrimaryV1`
2. **Batch API Calls** — Uses Microsoft Graph `$batch` endpoint to check synchronization jobs for up to 20 SPs per request
3. **Template Matching** — Compares each sync job's `templateId` against the 25 known Code Auth Grant run-profile tags
4. **Classification** — Labels each app as either:
   - `OAuth2 Authorization Code Grant` → **Action required**
   - `Other (Bearer Token / Client Credentials)` → **No action needed**

### Why Template Matching?

- The Entra ID synchronization API does not expose the OAuth grant type directly in the job metadata
- Apps that support Code Auth Grant use specific, well-known template IDs assigned by Microsoft
- This approach eliminates the need to inspect credential secrets or authorization configurations
- It dramatically reduces API calls compared to checking every SP's full sync configuration

### Error Handling

- If a batch request fails, the script falls back to individual per-SP API calls
- SPs without synchronization jobs are silently skipped (404 responses in batch are ignored)
- Permission errors are caught and logged without terminating the scan

---

## Remediation Steps

For each app flagged as using **OAuth 2.0 Authorization Code Grant**:

### 1. Open the Application in Entra ID Portal

Navigate to:
**Entra ID** → **Enterprise applications** → *Select the flagged app* → **Provisioning**

### 2. Update the Authorization Method

1. Click **Admin Credentials**
2. Under the **Authorization** section, switch from **Authorization Code** to **Client Credentials**
3. Enter the required credentials:
   - **Tenant URL**: The SCIM endpoint URL of the target application
   - **Client ID**: The OAuth 2.0 client ID from the target application
   - **Client Secret**: The OAuth 2.0 client secret from the target application
4. Click **Test Connection** to verify connectivity
5. Click **Save**

### 3. Restart Provisioning

1. Click **Stop provisioning** (if currently running)
2. Click **Start provisioning** to begin a new sync cycle with updated credentials

### 4. Verify

- Monitor the provisioning logs for successful sync cycles
- Re-run this scanner to confirm the app no longer appears in the "Action Required" list

> **Important**: Each SaaS vendor has specific instructions for generating Client Credentials. Refer to the vendor's documentation for the correct Tenant URL, Client ID, and Client Secret values.

---

## Automation and Scheduling

### Run as a Scheduled Task

To run the scanner on a recurring schedule (e.g., weekly compliance check):

```powershell
# Use app-only authentication for unattended execution
$clientId = "<your-app-registration-client-id>"
$tenantId = "<your-tenant-id>"
$certThumbprint = "<certificate-thumbprint>"

Connect-MgGraph -ClientId $clientId -TenantId $tenantId -CertificateThumbprint $certThumbprint
```

### Integration with Monitoring

- Parse the CSV output and push results to your SIEM, ServiceNow, or compliance dashboard
- Set up alerts when `IsCodeAuthGrant = TRUE` apps are detected
- Track remediation progress over time by comparing reports

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `Insufficient privileges` error | Ensure the account has `Application.Read.All` and `Synchronization.Read.All` permissions |
| Script returns 0 SCIM apps | Verify the tenant has SCIM provisioning configured for gallery apps |
| Batch API calls fail with 429 | The script handles throttling with fallback; try again after a few minutes |
| Module not found error | Run `Install-Module Microsoft.Graph.Applications -Force` |
| CSV file not created | Ensure the current directory is writable; check the terminal for the export path |

---

## Additional Resources

- [Microsoft Entra What's New — SCIM Auth Deprecation](https://learn.microsoft.com/en-us/entra/fundamentals/whats-new#plan-for-change---update-scim-provisioning-applications-to-use-modern-authentication)
- [Tutorial: Develop a SCIM endpoint in Entra ID](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/use-scim-to-provision-users-and-groups)
- [OAuth 2.0 Client Credentials Flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow)
- [Microsoft Graph Synchronization API](https://learn.microsoft.com/en-us/graph/api/resources/synchronization-overview)

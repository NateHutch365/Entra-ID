<#
.SYNOPSIS
Exports all Entra ID groups (M365 + security) and their owners to a CSV.

.EDIT ME
Change $CsvPath below to where you want the file saved.

.REQUIREMENTS
- Microsoft Graph PowerShell SDK
  Install-Module Microsoft.Graph -Scope CurrentUser
- Permission scope: Group.Read.All (minimum)
#>

# ===================== CONFIG =====================
# Put your desired full path (including filename) here:
$CsvPath = "D:\Reports\EntraGroupsWithOwners.csv"
# Optional: auto-timestamped example
# $CsvPath = "D:\Reports\EntraGroupsWithOwners_{0:yyyyMMdd_HHmm}.csv" -f (Get-Date)
# ==================================================

# Make sure the destination folder exists
$dir = Split-Path $CsvPath -Parent
if (-not (Test-Path $dir)) {
    Write-Host "Creating folder $dir ..."
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

# Connect to Graph if needed
if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "Group.Read.All"
}

# Pull groups
$groups = Get-MgGroup -All -Property Id,DisplayName,GroupTypes,SecurityEnabled,MailEnabled,MailNickname

# Build results
$results = foreach ($g in $groups) {

    $owners = Get-MgGroupOwner -GroupId $g.Id -All -ErrorAction SilentlyContinue

    $ownerNames = foreach ($o in $owners) {
        $o.DisplayName              `
            ?? $o.AdditionalProperties.displayName `
            ?? $o.AdditionalProperties.appDisplayName `
            ?? $o.Id
    }

    [pscustomobject]@{
        GroupId         = $g.Id
        DisplayName     = $g.DisplayName
        MailNickname    = $g.MailNickname
        Type            = if ($g.GroupTypes -contains 'Unified') { 'Microsoft 365' }
                          elseif ($g.SecurityEnabled)            { 'Security' }
                          else                                   { 'Other' }
        SecurityEnabled = $g.SecurityEnabled
        MailEnabled     = $g.MailEnabled
        Owners          = if ($ownerNames) { $ownerNames -join '; ' } else { '<none>' }
    }
}

# Export
$results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
Write-Host "Done. File saved to $CsvPath"

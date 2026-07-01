<#
.SYNOPSIS
    Adds a set of Entra ID (Azure AD) security groups to the "Excluded groups"
    list of every Conditional Access (CA) policy in the tenant.

.DESCRIPTION
    Given a list of group display names, this script:
      1. Resolves each group name to its Object ID via Microsoft Graph.
      2. Retrieves every Conditional Access policy in the tenant.
      3. Merges the resolved group IDs into each policy's
         Conditions.Users.ExcludeGroups list (without removing any existing
         includes/excludes/roles/guests settings already configured).
      4. Updates the policy via Microsoft Graph, unless -WhatIf is specified.

    Requires the Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns
    and Microsoft.Graph.Groups modules, and delegated/application permissions:
      Policy.Read.All, Policy.ReadWrite.ConditionalAccess,
      Group.Read.All (or Directory.Read.All)

.PARAMETER GroupNames
    One or more Entra ID security group display names to exclude from all CA
    policies.

.PARAMETER PolicyNames
    Optional. Restrict changes to CA policies whose DisplayName matches one of
    these values. If omitted, ALL Conditional Access policies are updated.

.PARAMETER Force
    Skip the confirmation prompt shown before applying changes.

.EXAMPLE
    .\Exclude-GroupsFromAllCAPolicies.ps1 -GroupNames "Break-Glass Accounts","Service Accounts - No MFA"

.EXAMPLE
    .\Exclude-GroupsFromAllCAPolicies.ps1 -GroupNames "Break-Glass Accounts" -WhatIf

.EXAMPLE
    .\Exclude-GroupsFromAllCAPolicies.ps1 -GroupNames "Break-Glass Accounts" -PolicyNames "Require MFA for all users","Block Legacy Auth"
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$GroupNames,

    [Parameter(Mandatory = $false)]
    [string[]]$PolicyNames,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

#region Prerequisites -------------------------------------------------------

$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Identity.SignIns',
    'Microsoft.Graph.Groups'
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing missing module: $module" -ForegroundColor Yellow
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module -Name $module -ErrorAction Stop
}

$requiredScopes = @(
    'Policy.Read.All',
    'Policy.ReadWrite.ConditionalAccess',
    'Group.Read.All'
)

$context = Get-MgContext
if (-not $context) {
    Connect-MgGraph -Scopes $requiredScopes | Out-Null
}
else {
    $missingScopes = $requiredScopes | Where-Object { $_ -notin $context.Scopes }
    if ($missingScopes) {
        Write-Host "Reconnecting to Microsoft Graph with additional scopes: $($missingScopes -join ', ')" -ForegroundColor Yellow
        Connect-MgGraph -Scopes $requiredScopes | Out-Null
    }
}

#endregion -------------------------------------------------------------------

#region Resolve group names to IDs -------------------------------------------

Write-Host "`nResolving group names to Object IDs..." -ForegroundColor Cyan

$resolvedGroups = @{}
$notFoundGroups = @()

foreach ($name in $GroupNames) {
    $escapedName = $name.Replace("'", "''")
    $group = Get-MgGroup -Filter "displayName eq '$escapedName'" -ConsistencyLevel eventual -CountVariable groupCount -All

    if (-not $group) {
        $notFoundGroups += $name
        Write-Warning "Group not found: '$name'"
        continue
    }

    if (@($group).Count -gt 1) {
        Write-Warning "Multiple groups matched name '$name'. Using the first match (Id: $($group[0].Id)). Consider renaming duplicates."
        $group = $group[0]
    }

    $resolvedGroups[$group.Id] = $name
    Write-Host "  Resolved '$name' -> $($group.Id)" -ForegroundColor Green
}

if ($resolvedGroups.Count -eq 0) {
    throw "None of the specified group names could be resolved. Aborting."
}

if ($notFoundGroups.Count -gt 0) {
    Write-Warning "The following groups were not found and will be skipped: $($notFoundGroups -join ', ')"
}

$newGroupIds = @($resolvedGroups.Keys)

#endregion ---------------------------------------------------------------------

#region Retrieve Conditional Access policies -----------------------------------

Write-Host "`nRetrieving Conditional Access policies..." -ForegroundColor Cyan

$allPolicies = Get-MgIdentityConditionalAccessPolicy -All

if ($PolicyNames) {
    $policies = $allPolicies | Where-Object { $_.DisplayName -in $PolicyNames }
    $missingPolicyNames = $PolicyNames | Where-Object { $_ -notin $policies.DisplayName }
    if ($missingPolicyNames) {
        Write-Warning "The following policy names were not found: $($missingPolicyNames -join ', ')"
    }
}
else {
    $policies = $allPolicies
}

if (-not $policies -or @($policies).Count -eq 0) {
    throw "No matching Conditional Access policies were found. Aborting."
}

Write-Host "Found $(@($policies).Count) polic$(if (@($policies).Count -eq 1) { 'y' } else { 'ies' }) to evaluate.`n" -ForegroundColor Cyan

#endregion -----------------------------------------------------------------------

#region Update each policy --------------------------------------------------------

$summary = [System.Collections.Generic.List[object]]::new()

if (-not $Force -and $PSCmdlet.ShouldProcess("$(@($policies).Count) Conditional Access polic(y/ies)", "Add $(@($newGroupIds).Count) group(s) to ExcludeGroups")) {
    # ShouldProcess already prompts; nothing extra needed here.
}
elseif ($Force) {
    Write-Host "Force specified, skipping confirmation prompt." -ForegroundColor Yellow
}

foreach ($policy in $policies) {
    $existingUsers = $policy.Conditions.Users

    $existingExcludeGroups = @()
    if ($existingUsers.AdditionalProperties.ContainsKey('excludeGroups')) {
        $existingExcludeGroups = @($existingUsers.AdditionalProperties['excludeGroups'])
    }
    elseif ($existingUsers.ExcludeGroups) {
        $existingExcludeGroups = @($existingUsers.ExcludeGroups)
    }

    $mergedExcludeGroups = @($existingExcludeGroups + $newGroupIds | Select-Object -Unique)
    $groupsToAdd = @($newGroupIds | Where-Object { $_ -notin $existingExcludeGroups })

    if ($groupsToAdd.Count -eq 0) {
        Write-Host "[SKIP]   '$($policy.DisplayName)' already excludes all specified groups." -ForegroundColor DarkGray
        $summary.Add([pscustomobject]@{
            PolicyName = $policy.DisplayName
            Status     = 'Skipped (already excluded)'
            GroupsAdded = 0
        })
        continue
    }

    $addedNames = $groupsToAdd | ForEach-Object { $resolvedGroups[$_] }

    $bodyUsers = @{
        includeUsers                     = $existingUsers.IncludeUsers
        excludeUsers                      = $existingUsers.ExcludeUsers
        includeGroups                     = $existingUsers.IncludeGroups
        excludeGroups                     = $mergedExcludeGroups
        includeRoles                      = $existingUsers.IncludeRoles
        excludeRoles                      = $existingUsers.ExcludeRoles
        includeGuestsOrExternalUsers       = $existingUsers.IncludeGuestsOrExternalUsers
        excludeGuestsOrExternalUsers       = $existingUsers.ExcludeGuestsOrExternalUsers
    }

    # Remove null keys so we don't send empty overrides for properties never set.
    $keysToRemove = $bodyUsers.Keys | Where-Object { $null -eq $bodyUsers[$_] } | ForEach-Object { $_ }
    foreach ($key in $keysToRemove) { $bodyUsers.Remove($key) }

    $bodyParams = @{
        conditions = @{
            users = $bodyUsers
        }
    }

    $target = "'$($policy.DisplayName)' (Id: $($policy.Id))"
    $action = "Add group(s) [$($addedNames -join ', ')] to ExcludeGroups"

    if ($PSCmdlet.ShouldProcess($target, $action)) {
        try {
            Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -BodyParameter $bodyParams
            Write-Host "[UPDATED] $target -> added: $($addedNames -join ', ')" -ForegroundColor Green
            $summary.Add([pscustomobject]@{
                PolicyName  = $policy.DisplayName
                Status      = 'Updated'
                GroupsAdded = $groupsToAdd.Count
            })
        }
        catch {
            Write-Error "Failed to update policy '$($policy.DisplayName)': $($_.Exception.Message)"
            $summary.Add([pscustomobject]@{
                PolicyName  = $policy.DisplayName
                Status      = "Error: $($_.Exception.Message)"
                GroupsAdded = 0
            })
        }
    }
    else {
        $summary.Add([pscustomobject]@{
            PolicyName  = $policy.DisplayName
            Status      = 'WhatIf (no changes made)'
            GroupsAdded = $groupsToAdd.Count
        })
    }
}

#endregion -------------------------------------------------------------------------

Write-Host "`n===== Summary =====" -ForegroundColor Cyan
$summary | Format-Table -AutoSize

if ($notFoundGroups.Count -gt 0) {
    Write-Host "`nGroups not found and skipped: $($notFoundGroups -join ', ')" -ForegroundColor Yellow
}

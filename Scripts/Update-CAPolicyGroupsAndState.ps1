<#
.SYNOPSIS
    Adds sets of Entra ID (Azure AD) security groups to the "Included groups"
    and/or "Excluded groups" list of every Conditional Access (CA) policy in
    the tenant, and/or updates the state (On / Off / Report-only) of those
    policies.

.DESCRIPTION
    Given one or two lists of group display names, this script:
      1. Resolves each group name to its Object ID via Microsoft Graph.
      2. Retrieves every Conditional Access policy in the tenant.
      3. Merges the resolved group IDs into each policy's
         Conditions.Users.IncludeGroups (from -IncludeGroupNames) and/or
         Conditions.Users.ExcludeGroups (from -ExcludeGroupNames) list,
         without removing any existing includes/excludes/roles/guests
         settings already configured.
      4. Updates the policy via Microsoft Graph, unless -WhatIf is specified.

    Requires the Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns
    and Microsoft.Graph.Groups modules, and delegated/application permissions:
      Policy.Read.All, Policy.ReadWrite.ConditionalAccess,
      Group.Read.All (or Directory.Read.All)

.PARAMETER IncludeGroupNames
    One or more Entra ID security group display names to add to the "Include"
    assignment of all matching CA policies.

.PARAMETER ExcludeGroupNames
    One or more Entra ID security group display names to add to the "Exclude"
    assignment of all matching CA policies.

    At least one of -IncludeGroupNames or -ExcludeGroupNames must be
    specified. Both may be used together, with different groups in each, in
    a single run.

.PARAMETER State
    Optional. Sets the state of every matching CA policy. Accepts:
      On          -> enabled
      Off         -> disabled
      Report-only -> enabledForReportingButNotEnforced

    May be used on its own (no group changes) or combined with
    -IncludeGroupNames / -ExcludeGroupNames.

.PARAMETER PolicyNames
    Optional. Restrict changes to CA policies whose DisplayName matches one of
    these values. If omitted, ALL Conditional Access policies are updated.

.PARAMETER Force
    Skip the confirmation prompt shown before applying changes.

.EXAMPLE
    .\Update-CAPolicyGroupsAndState.ps1 -ExcludeGroupNames "Break-Glass Accounts","Service Accounts - No MFA"

.EXAMPLE
    .\Update-CAPolicyGroupsAndState.ps1 -ExcludeGroupNames "Break-Glass Accounts" -WhatIf

.EXAMPLE
    .\Update-CAPolicyGroupsAndState.ps1 -ExcludeGroupNames "Break-Glass Accounts" -PolicyNames "Require MFA for all users","Block Legacy Auth"

.EXAMPLE
    .\Update-CAPolicyGroupsAndState.ps1 -IncludeGroupNames "Contractors"

.EXAMPLE
    .\Update-CAPolicyGroupsAndState.ps1 -IncludeGroupNames "CA-Test1" -ExcludeGroupNames "CA-Test2"

.EXAMPLE
    .\Update-CAPolicyGroupsAndState.ps1 -ExcludeGroupNames "Break-Glass Accounts" -State Report-only

.EXAMPLE
    .\Update-CAPolicyGroupsAndState.ps1 -State On -PolicyNames "Block Legacy Auth"
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$IncludeGroupNames,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeGroupNames,

    [Parameter(Mandatory = $false)]
    [ValidateSet('On', 'Off', 'Report-only')]
    [string]$State,

    [Parameter(Mandatory = $false)]
    [string[]]$PolicyNames,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $IncludeGroupNames -and -not $ExcludeGroupNames -and -not $State) {
    throw "You must specify at least one of -IncludeGroupNames, -ExcludeGroupNames or -State."
}

# Map the friendly -State values to the Microsoft Graph conditionalAccessPolicyState enum.
$stateMap = @{
    'On'          = 'enabled'
    'Off'         = 'disabled'
    'Report-only' = 'enabledForReportingButNotEnforced'
}
$targetState = if ($State) { $stateMap[$State] } else { $null }

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

$resolvedGroups = @{}       # Id -> DisplayName
$resolvedNameToId = @{}     # DisplayName -> Id
$notFoundGroups = @()

$allGroupNames = @(@($IncludeGroupNames) + @($ExcludeGroupNames) | Where-Object { $_ } | Select-Object -Unique)

foreach ($name in $allGroupNames) {
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
    $resolvedNameToId[$name] = $group.Id
    Write-Host "  Resolved '$name' -> $($group.Id)" -ForegroundColor Green
}

if ($resolvedGroups.Count -eq 0 -and ($IncludeGroupNames -or $ExcludeGroupNames)) {
    throw "None of the specified group names could be resolved. Aborting."
}

if ($notFoundGroups.Count -gt 0) {
    Write-Warning "The following groups were not found and will be skipped: $($notFoundGroups -join ', ')"
}

$includeGroupIds = [string[]]@($IncludeGroupNames | Where-Object { $resolvedNameToId.ContainsKey($_) } | ForEach-Object { $resolvedNameToId[$_] } | Select-Object -Unique)
$excludeGroupIds = [string[]]@($ExcludeGroupNames | Where-Object { $resolvedNameToId.ContainsKey($_) } | ForEach-Object { $resolvedNameToId[$_] } | Select-Object -Unique)

if (($IncludeGroupNames -or $ExcludeGroupNames) -and $includeGroupIds.Count -eq 0 -and $excludeGroupIds.Count -eq 0) {
    throw "None of the specified group names could be resolved for either Include or Exclude. Aborting."
}

#endregion ---------------------------------------------------------------------

#region Helper functions --------------------------------------------------------

function Get-PolicyGroupIds {
    <#
        Returns the group IDs currently assigned to the given property
        ('includeGroups' or 'excludeGroups') of a CA policy's Users
        conditions, preferring the raw AdditionalProperties value (as
        returned by the Graph SDK) and falling back to the typed property.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Users,

        [Parameter(Mandatory = $true)]
        [ValidateSet('includeGroups', 'excludeGroups')]
        [string]$PropertyName
    )

    if ($Users.AdditionalProperties.ContainsKey($PropertyName)) {
        return [string[]]@($Users.AdditionalProperties[$PropertyName])
    }

    $typedValue = if ($PropertyName -eq 'includeGroups') { $Users.IncludeGroups } else { $Users.ExcludeGroups }
    if ($typedValue) {
        return [string[]]@($typedValue)
    }

    return [string[]]@()
}

#endregion -----------------------------------------------------------------------

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

$assignmentLabels = @()
if ($includeGroupIds.Count -gt 0) { $assignmentLabels += 'Include' }
if ($excludeGroupIds.Count -gt 0) { $assignmentLabels += 'Exclude' }
$assignmentTypesLabel = $assignmentLabels -join ' and '

$operationParts = @()
if ($assignmentTypesLabel) { $operationParts += "add group(s) to $assignmentTypesLabel groups" }
if ($targetState) { $operationParts += "set state to '$State' ($targetState)" }
$operationLabel = $operationParts -join ' and '

if (-not $Force -and $PSCmdlet.ShouldProcess("$(@($policies).Count) Conditional Access polic(y/ies)", "$operationLabel")) {
    # ShouldProcess already prompts; nothing extra needed here.
}
elseif ($Force) {
    Write-Host "Force specified, skipping confirmation prompt." -ForegroundColor Yellow
}

foreach ($policy in $policies) {
    $existingUsers = $policy.Conditions.Users

    $existingIncludeGroups = Get-PolicyGroupIds -Users $existingUsers -PropertyName 'includeGroups'
    $existingExcludeGroups = Get-PolicyGroupIds -Users $existingUsers -PropertyName 'excludeGroups'

    $finalIncludeGroups = $existingIncludeGroups
    $finalExcludeGroups = $existingExcludeGroups
    $changeDescriptions = [System.Collections.Generic.List[string]]::new()
    $totalGroupsAdded = 0
    $hasGroupChanges = $false

    if ($includeGroupIds.Count -gt 0) {
        $groupsToAdd = @($includeGroupIds | Where-Object { $_ -notin $existingIncludeGroups })

        if ($groupsToAdd.Count -eq 0) {
            Write-Host "[SKIP]   '$($policy.DisplayName)' already has all specified groups in Include Groups." -ForegroundColor DarkGray
        }
        else {
            $finalIncludeGroups = [string[]]@(@($existingIncludeGroups) + @($includeGroupIds) | Select-Object -Unique)
            $addedNames = $groupsToAdd | ForEach-Object { $resolvedGroups[$_] }
            $changeDescriptions.Add("Include: $($addedNames -join ', ')")
            $totalGroupsAdded += $groupsToAdd.Count
            $hasGroupChanges = $true
        }
    }

    if ($excludeGroupIds.Count -gt 0) {
        $groupsToAdd = @($excludeGroupIds | Where-Object { $_ -notin $existingExcludeGroups })

        if ($groupsToAdd.Count -eq 0) {
            Write-Host "[SKIP]   '$($policy.DisplayName)' already has all specified groups in Exclude Groups." -ForegroundColor DarkGray
        }
        else {
            $finalExcludeGroups = [string[]]@(@($existingExcludeGroups) + @($excludeGroupIds) | Select-Object -Unique)
            $addedNames = $groupsToAdd | ForEach-Object { $resolvedGroups[$_] }
            $changeDescriptions.Add("Exclude: $($addedNames -join ', ')")
            $totalGroupsAdded += $groupsToAdd.Count
            $hasGroupChanges = $true
        }
    }

    if ($targetState -and $policy.State -ne $targetState) {
        $changeDescriptions.Add("State: $($policy.State) -> $targetState")
    }

    if ($changeDescriptions.Count -eq 0) {
        $summary.Add([pscustomobject]@{
            PolicyName = $policy.DisplayName
            Status     = "Skipped (no changes needed)"
            GroupsAdded = 0
        })
        continue
    }

    $bodyParams = @{}

    if ($hasGroupChanges) {
        $bodyUsers = @{
            includeUsers  = $existingUsers.IncludeUsers
            excludeUsers  = $existingUsers.ExcludeUsers
            includeGroups = [string[]]$finalIncludeGroups
            excludeGroups = [string[]]$finalExcludeGroups
            includeRoles  = $existingUsers.IncludeRoles
            excludeRoles  = $existingUsers.ExcludeRoles
        }

        # Only send guests/external-users conditions when they are actually configured.
        # Graph rejects a present-but-empty object (i.e. with a null guestOrExternalUserTypes),
        # which is what the typed SDK property returns when the setting was never set.
        if ($existingUsers.IncludeGuestsOrExternalUsers -and $existingUsers.IncludeGuestsOrExternalUsers.GuestOrExternalUserTypes) {
            $bodyUsers['includeGuestsOrExternalUsers'] = $existingUsers.IncludeGuestsOrExternalUsers
        }
        if ($existingUsers.ExcludeGuestsOrExternalUsers -and $existingUsers.ExcludeGuestsOrExternalUsers.GuestOrExternalUserTypes) {
            $bodyUsers['excludeGuestsOrExternalUsers'] = $existingUsers.ExcludeGuestsOrExternalUsers
        }

        # Remove null keys so we don't send empty overrides for properties never set.
        $keysToRemove = $bodyUsers.Keys | Where-Object { $null -eq $bodyUsers[$_] } | ForEach-Object { $_ }
        foreach ($key in $keysToRemove) { $bodyUsers.Remove($key) }

        $bodyParams['conditions'] = @{
            users = $bodyUsers
        }
    }

    if ($targetState -and $policy.State -ne $targetState) {
        $bodyParams['state'] = $targetState
    }

    $target = "'$($policy.DisplayName)' (Id: $($policy.Id))"
    $action = "Update - $($changeDescriptions -join '; ')"

    $jsonBody = $bodyParams | ConvertTo-Json -Depth 10
    Write-Verbose "Request body for $target :`n$jsonBody"

    if ($PSCmdlet.ShouldProcess($target, $action)) {
        try {
            # NOTE: Update-MgIdentityConditionalAccessPolicy's -BodyParameter (Hashtable)
            # conversion has been observed to corrupt sibling includeGroups/excludeGroups
            # array values (concatenating group IDs into a single invalid string). Calling
            # the Graph endpoint directly with a manually serialized JSON body avoids that
            # cmdlet-side conversion entirely.
            Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$($policy.Id)" -Body $jsonBody -ContentType 'application/json' | Out-Null
            Write-Host "[UPDATED] $target -> $($changeDescriptions -join '; ')" -ForegroundColor Green
            $summary.Add([pscustomobject]@{
                PolicyName  = $policy.DisplayName
                Status      = 'Updated'
                GroupsAdded = $totalGroupsAdded
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
            GroupsAdded = $totalGroupsAdded
        })
    }
}

#endregion -------------------------------------------------------------------------

Write-Host "`n===== Summary =====" -ForegroundColor Cyan
$summary | Format-Table -AutoSize

if ($notFoundGroups.Count -gt 0) {
    Write-Host "`nGroups not found and skipped: $($notFoundGroups -join ', ')" -ForegroundColor Yellow
}

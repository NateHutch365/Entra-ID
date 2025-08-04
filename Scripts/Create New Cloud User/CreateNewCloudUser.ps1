# Connect (v1.0 profile is fine)
Connect-MgGraph -Scopes "User.ReadWrite.All","User-LifeCycleInfo.ReadWrite.All"
# Select-MgProfile -Name "v1.0"

# === INPUTS (edit these) ===
$GivenName           = "Samantha"
$Surname             = "Young"
$Domain              = "contoso.com"     # tenant domain

$Department          = "Finance"
$JobTitle            = "Analyst"
$CompanyName         = "Contoso Ltd"
$OfficeLocation      = "London HQ"

$UsageLocation       = "GB"                       # ISO 3166-1 alpha-2; required for licensing
$Country             = "United Kingdom"           # Country or region (Graph property: 'country'; free text)

$EmployeeId          = "FIN-00422"
$EmployeeType        = "Employee"                 # e.g., Employee | Contractor | Vendor
$EmployeeHireDate    = "2025-08-03T00:00:00Z"     # ISO 8601 UTC
# Optional:
# $EmployeeLeaveDateTime = "2026-09-01T00:00:00Z"

# Build identity values (Proper Case for first/last; domain lower-case)
$ti                 = (Get-Culture).TextInfo
$GivenNamePC        = $ti.ToTitleCase($GivenName.ToLower())
$SurnamePC          = $ti.ToTitleCase($Surname.ToLower())
$DisplayName        = "$GivenNamePC $SurnamePC"
$MailNickname       = "$GivenNamePC.$SurnamePC"                      # e.g., Samantha.Young
$UserPrincipalName  = "$GivenNamePC.$SurnamePC@$($Domain.ToLower())" # e.g., Samantha.Young@...

# ------------ Helper functions (password generation & secure conversion) ------------
function New-CryptoRandomInt {
    param([int]$MaxExclusive)
    $b = New-Object byte[] 4
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    $n = [System.BitConverter]::ToUInt32($b,0)
    return [int]($n % $MaxExclusive)
}

function New-StrongSecurePassword {
    param([int]$Length = 16)
    if ($Length -lt 12) { throw "Length must be >= 12" }

    $lower   = 'abcdefghjkmnpqrstuvwxyz'.ToCharArray()
    $upper   = 'ABCDEFGHJKMNPQRSTUVWXYZ'.ToCharArray()
    $digits  = '23456789'.ToCharArray()
    $symbols = '!@#%^&*()-_=+[]{}:;,.?'.ToCharArray()

    $pool = @($lower + $upper + $digits + $symbols)

    # Ensure at least one from each category
    $chars = New-Object System.Collections.Generic.List[char]
    $chars.Add($lower[(New-CryptoRandomInt -MaxExclusive $lower.Length)])
    $chars.Add($upper[(New-CryptoRandomInt -MaxExclusive $upper.Length)])
    $chars.Add($digits[(New-CryptoRandomInt -MaxExclusive $digits.Length)])
    $chars.Add($symbols[(New-CryptoRandomInt -MaxExclusive $symbols.Length)])

    # Fill the rest randomly
    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars.Add($pool[(New-CryptoRandomInt -MaxExclusive $pool.Count)])
    }

    # Fisher–Yates shuffle
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = New-CryptoRandomInt -MaxExclusive ($i + 1)
        if ($j -ne $i) {
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
    }

    # Build SecureString
    $sec = New-Object System.Security.SecureString
    foreach ($c in $chars) { $sec.AppendChar($c) }
    $sec.MakeReadOnly()
    return $sec
}

function ConvertFrom-SecureStringPlain {
    <#
      Converts a SecureString to plain text for *immediate* use.
      The caller MUST clear the returned string ASAP.
    #>
    param([Parameter(Mandatory)][System.Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}
# -------------------------------------------------------------------------

# OPTION A: Auto-generate a strong SecureString temp password (recommended)
$SecureTemp = New-StrongSecurePassword -Length 16

# OPTION B: Manual password entry (also a SecureString)
# $SecureTemp = Read-Host -Prompt "Enter a temporary password" -AsSecureString

# Prepare parameters (convert to plain text only at the last moment)
$params = @{
  AccountEnabled    = $true
  DisplayName       = $DisplayName
  GivenName         = $GivenNamePC
  Surname           = $SurnamePC
  UserPrincipalName = $UserPrincipalName
  MailNickname      = $MailNickname

  Department        = $Department
  JobTitle          = $JobTitle
  CompanyName       = $CompanyName
  OfficeLocation    = $OfficeLocation

  UsageLocation     = $UsageLocation     # 2-letter ISO code
  Country           = $Country           # Country/region (free text)

  EmployeeId        = $EmployeeId
  EmployeeType      = $EmployeeType
  EmployeeHireDate  = $EmployeeHireDate
  # EmployeeLeaveDateTime = $EmployeeLeaveDateTime  # uncomment if you’re setting it now

  # Optional: set primary SMTP to match alias (some orgs set this later via EXO)
  # ProxyAddresses    = @("SMTP:$MailNickname@$($Domain.ToLower())")

  # Placeholder - password added just-in-time below
  PasswordProfile   = @{
    Password                      = $null
    ForceChangePasswordNextSignIn = $true
  }

  PreferredLanguage = "en-GB"
}

# Try create; if Graph rejects password, regenerate & retry
$NewUser = $null
$maxAttempts = 3
for ($attempt = 1; $attempt -le $maxAttempts -and -not $NewUser; $attempt++) {
    $plain = ConvertFrom-SecureStringPlain -Secure $SecureTemp
    try {
        $params.PasswordProfile.Password = $plain
        $NewUser = New-MgUser @params -ErrorAction Stop
    }
    catch {
        $message = $_.Exception.Message
        if ($attempt -lt $maxAttempts -and ($message -match 'does not comply with password complexity' -or $message -match 'Password is too weak' -or $message -match 'banned')) {
            Write-Warning "Graph rejected the candidate (attempt $attempt). Generating a new password and retrying..."
            $SecureTemp = New-StrongSecurePassword -Length 20
        } else {
            throw
        }
    }
    finally {
        # Minimize plaintext exposure
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR(
            [System.Runtime.InteropServices.Marshal]::StringToBSTR($plain)
        )
        $plain = $null
        $params.PasswordProfile.Password = $null
    }
}

if ($NewUser) {
    # OPTIONAL: reveal password for handover (off by default; set $true to enable)
    $RevealTempToConsole = $false
    if ($RevealTempToConsole) {
        $reveal = ConvertFrom-SecureStringPlain -Secure $SecureTemp
        try { Write-Host "Temporary password for $($NewUser.UserPrincipalName): $reveal" }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR(
                [System.Runtime.InteropServices.Marshal]::StringToBSTR($reveal)
            )
            $reveal = $null
        }
    }

    # Verify key properties (employeeHireDate must be requested)
    $Check = Get-MgUser -UserId $NewUser.Id -Property "id,displayName,userPrincipalName,mailNickname,department,country,employeeHireDate,jobTitle,usageLocation,proxyAddresses"
    $Check | Select-Object Id, DisplayName, UserPrincipalName, MailNickname, Department, Country, EmployeeHireDate, JobTitle, UsageLocation, ProxyAddresses
} else {
    Write-Error "User creation failed after $maxAttempts attempt(s)."
}

# Final hygiene
$SecureTemp = $null

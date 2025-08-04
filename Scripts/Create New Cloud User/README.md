# Entra ID New User Creation Script — README

This script creates a new **Entra ID** (Azure AD) user with a temporary password, and sets core HR/Org properties (hire date, department, job title, office, usage location, country). It also includes safe password generation, minimal plaintext exposure, and a retry for banned/weak passwords.

---

## What the script does

* Connects to Microsoft Graph (you must sign in with appropriate permissions).
* Builds a **proper‑cased UPN and mailNickname** in the format `Firstname.Lastname@domain`.
* Generates a **strong SecureString** password (or you can supply one) and converts it to clear text **only** for the `New-MgUser` call.
* Creates the user and sets:

  * `department`, `jobTitle`, `companyName`, `officeLocation`
  * `usageLocation` (2‑letter ISO) and `country` (free text)
  * `employeeId`, `employeeType`, `employeeHireDate`
* Optionally: you can stamp the **primary SMTP** to match the alias.
* Outputs a quick verification of key properties after creation.

> **Does not**: assign licenses, add to groups, set manager, or provision mailbox.

---

## Prerequisites

* **PowerShell 7+** (recommended) or Windows PowerShell 5.1.
* **Microsoft Graph PowerShell SDK**

  ```powershell
  Install-Module Microsoft.Graph -Scope CurrentUser
  ```
* **Permissions/Roles**

  * App/Delegated scopes requested at connect: `User.ReadWrite.All` (and `User-LifeCycleInfo.ReadWrite.All` if you set `EmployeeLeaveDateTime`).
  * Directory role: **User Administrator** or **Global Administrator** (to create users and set lifecycle properties).
* **Verified domain**: the value in `$Domain` must be a verified/accepted domain in your tenant.

---

## How to run it (quick start)

1. Update the **Inputs** block at the top: names, domain, department, office, etc.
2. (Optional) Decide how you want the **primary SMTP** stamped (see [Primary SMTP options](#primary-smtp-options)).
3. Run the script. When prompted by Graph, sign in with an account that has the required permissions.
4. Review the output object for `Id`, `UserPrincipalName`, `MailNickname`, and other properties.

> The script sets the UPN and alias in **Proper Case** (e.g., `Samantha.Young@contoso.com`) but remember: sign‑in and email are case‑insensitive and many portals display them in lowercase.

---

## Inputs and what they mean

| Variable                 | Required | Example                  | Notes                                            |
| ------------------------ | :------: | ------------------------ | ------------------------------------------------ |
| `$GivenName`, `$Surname` |    ✔️    | `"Samantha"`, `"Young"`  | Used to build DisplayName, UPN, and mailNickname |
| `$Domain`                |    ✔️    | `"contoso.com"`          | Must be a verified Entra ID domain               |
| `$Department`            |    ✔️    | `"Finance"`              | String                                           |
| `$JobTitle`              |          | `"Analyst"`              | String                                           |
| `$CompanyName`           |          | `"Contoso Ltd"`          | String                                           |
| `$OfficeLocation`        |          | `"London HQ"`            | String                                           |
| `$UsageLocation`         |    ✔️    | `"GB"`                   | Two‑letter ISO code; required before licensing   |
| `$Country`               |          | `"United Kingdom"`       | Free‑text country/region (Graph `country`)       |
| `$EmployeeId`            |          | `"FIN-00422"`            | External/HR identifier                           |
| `$EmployeeType`          |          | `"Employee"`             | e.g., Employee, Contractor, Vendor               |
| `$EmployeeHireDate`      |    ✔️    | `"2025-08-03T00:00:00Z"` | ISO 8601 UTC string                              |
| `$EmployeeLeaveDateTime` |          |                          | Optional; uncomment to set at create time        |

### Derived values

* **Proper case** versions of the name are generated using the current culture and used for:

  * `$DisplayName`: `Firstname Lastname`
  * `$MailNickname`: `Firstname.Lastname`
  * `$UserPrincipalName`: `Firstname.Lastname@domain`

---

## Password handling

* The script **generates a password** with at least one lower, upper, digit, and symbol, using a cryptographically secure RNG.
* Password is stored as a **`SecureString`**; it is converted to plaintext **only** just before calling `New-MgUser`, then zeroed out.
* If Graph rejects the password (banned list/complexity), the script **regenerates** a stronger/longer one and retries (up to 3 attempts).
* Printing the password is **off by default**. Toggle `$RevealTempToConsole = $true` to echo it once (for handover). Use sparingly.

---

## Primary SMTP options

You can control the user’s primary SMTP address if you want it to match the alias `Firstname.Lastname@domain`.

**A) At create time via `ProxyAddresses`**

```powershell
# In $params
ProxyAddresses = @("SMTP:$MailNickname@$($Domain.ToLower())")
```

* Uppercase `SMTP:` sets the **primary** address. Lowercase `smtp:` adds an alias.
* Some tenants may restrict writing `proxyAddresses` directly; if you see a Graph error, use B or C.

**B) At create time via `Mail`**

```powershell
# In $params
Mail = "$MailNickname@$($Domain.ToLower())"
```

* Setting `mail` can also populate `proxyAddresses` for the user.

**C) After licensing via Exchange Online**

```powershell
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline
Set-Mailbox -Identity $UserPrincipalName -PrimarySmtpAddress "$MailNickname@$($Domain.ToLower())"
```

* Most reliable once the mailbox has provisioned.

> If you manage SMTPs centrally (policies/automation), you can skip A/B here and do it in EXO later.

---

## What to expect on success

* The script returns a `Get-MgUser` projection with:

  * `Id`, `DisplayName`, `UserPrincipalName`, `MailNickname`
  * `Department`, `Country`, `EmployeeHireDate`, `JobTitle`, `UsageLocation`
  * (If enabled) `ProxyAddresses`

---

## Troubleshooting

**Password rejected**

* Message: *"does not comply with password complexity"*, *"Password is too weak"*, or *banned list*.
* Action: Let the script retry; if it still fails, increase length or try again later (tenant policies may be stricter).

**400 Bad Request on `proxyAddresses`**

* Some environments block direct writes. Use option **B** (`Mail`) or **C** (EXO) under Primary SMTP options.

**UPN/alias collision**

* If a user or contact already exists with the same UPN/alias, pick a different `$MailNickname` or adjust the UPN logic.

**Insufficient privileges**

* Ensure you’re connecting with `User.ReadWrite.All` and an account with **User Administrator** or higher.

**Domain not verified**

* `$Domain` must be accepted in Entra ID and in Exchange Online for SMTP stamping.

---

## Common extensions (optional)

* **Assign a license** after setting `UsageLocation`.
* **Add to groups** (static) with `Add-MgGroupMember` or use **dynamic groups** (e.g., by `employeeHireDate` and `department`).
* **Set manager** after creation using `Set-MgUserManager`.
* **Set address/phone** with `city`, `state`, `postalCode`, `mobilePhone`, `businessPhones`.

---

## Security considerations

* Avoid printing or logging plaintext passwords. Keep `$RevealTempToConsole` disabled unless necessary.
* Store the script in a secure repo; consider adding a transcript/log scrubber.
* Consider a **function** wrapper (`New-OrgCloudUser`) with parameter validation if you’ll use this broadly.

---

## Example: minimal changes and run

```powershell
$GivenName = "Samantha"
$Surname   = "Young"
$Domain    = "contoso.com"
$Department = "Finance"
$UsageLocation = "GB"
$Country = "United Kingdom"
$EmployeeHireDate = "2025-08-03T00:00:00Z"

# Run the rest of the script as-is
```

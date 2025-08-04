# Export-EntraGroupsWithOwners

PowerShell script that exports **all Entra ID (Azure AD) groups** — including **Microsoft 365 (Unified)** and **Security** groups — with their **owners** to a CSV using the **Microsoft Graph PowerShell SDK**.

---

## ✨ What it does

* Enumerates every group in your tenant
* Resolves **owners** (users, service principals, etc.)
* Classifies groups as **Microsoft 365**, **Security**, or **Other**
* Writes a clean CSV with one row per group

---

## 🚀 Quick Start

1. **Install the Graph SDK** (once):

   ```powershell
   Install-Module Microsoft.Graph -Scope CurrentUser
   ```
2. **Open the script** and set your preferred export path:

   ```powershell
   # ===================== CONFIG =====================
   $CsvPath = "D:\Reports\EntraGroupsWithOwners.csv"
   # Optional: timestamped
   # $CsvPath = "D:\Reports\EntraGroupsWithOwners_{0:yyyyMMdd_HHmm}.csv" -f (Get-Date)
   # ==================================================
   ```
3. **Run it** (from the script folder):

   ```powershell
   # allow script for this session, if needed
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

   .\Export-EntraGroupsWithOwners.ps1
   ```

   You’ll be prompted to sign in to Microsoft Graph the first time.

---

## 📦 Output

**CSV columns**

* `GroupId` — Object ID
* `DisplayName` — Group name
* `MailNickname` — Alias (for mail-enabled groups)
* `Type` — `Microsoft 365`, `Security`, or `Other`
* `SecurityEnabled` — `True`/`False`
* `MailEnabled` — `True`/`False`
* `Owners` — `;`-separated list of owner display names, or `<none>`

**Example**

```csv
GroupId,DisplayName,MailNickname,Type,SecurityEnabled,MailEnabled,Owners
11111111-1111-1111-1111-111111111111,Marketing Team,marketing,Microsoft 365,False,True,"Adele Vance; Alex Wilber"
22222222-2222-2222-2222-222222222222,HR-Priv,hr-priv,Security,True,False,<none>
```

---

## 🔐 Permissions

The script connects using **delegated** Graph permissions and requests:

* `Group.Read.All`

> An administrator may need to **grant consent** in your tenant if it hasn’t been approved before.

**National clouds**

```powershell
# Example: US Government
Connect-MgGraph -Environment AzureUSGovernment -Scopes "Group.Read.All"
```

---

## 🧩 Requirements

* PowerShell **5.1 or 7+**
* **Microsoft Graph PowerShell SDK** (`Microsoft.Graph`)
* Access to sign in with an account that can read groups & owners

Update the SDK when needed:

```powershell
Update-Module Microsoft.Graph
```

---

## ⚙️ How it works (summary)

* Gets all groups with minimal properties: `Id`, `DisplayName`, `GroupTypes`, `SecurityEnabled`, `MailEnabled`, `MailNickname`.
* Identifies Microsoft 365 groups via `GroupTypes -contains 'Unified'`.
* For each group, calls `Get-MgGroupOwner -All` and normalizes an owner name from `DisplayName` (or falls back to `AdditionalProperties`).
* Emits one PSCustomObject per group and exports with `Export-Csv -Encoding UTF8`.

---

## 🏎️ Performance & scale tips

* **Test first**: while iterating, try `Get-MgGroup -First 50` to validate output.
* **Large tenants (10k+ groups)**: consider a batching variant using Graph `$batch` to fetch owners in fewer round-trips. Open an issue if you want this added here.
* Avoid very chatty consoles; redirect verbose logs if you add them.

---

## ❗ Troubleshooting

* **`Get-MgContext` not recognized**: Ensure `Microsoft.Graph` is installed/imported and you spelled cmdlets correctly.
* **Sign-in / consent loop**: An admin may need to approve `Group.Read.All`.
* **`403 Forbidden`**: Your account lacks permission; request access or use an admin-approved account.
* **No owners listed**: Some groups legitimately have no owners or the owners are service principals; the CSV will show `<none>`.
* **National clouds**: Use `-Environment` with `Connect-MgGraph`.

---

## 🔄 Variants (optional)

Prefer passing a path at runtime? Here’s a parameterized launch pattern you can adapt:

```powershell
param([string]$CsvPath)
if (-not $CsvPath) { $CsvPath = Join-Path (Get-Location) 'EntraGroupsWithOwners.csv' }
```

Then run:

```powershell
.\Export-EntraGroupsWithOwners.ps1 -CsvPath "D:\Reports\Entra.csv"
```

---

## 📁 Repo layout

```
/Export-EntraGroupsWithOwners.ps1   # main script
/README.md                          # this file
```

---

## 🪪 License

MIT — see `LICENSE`.

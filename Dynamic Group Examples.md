# Entra ID Dynamic Security Group Examples

A collection of dynamic security group membership rules for Microsoft Entra ID (formerly Azure AD).

## Table of Contents
- [User-Based Groups](#user-based-groups)
- [Device-Based Groups](#device-based-groups)
- [Best Practices](#best-practices)

## User-Based Groups

### Department-Based Groups

#### Marketing Department
```
user.department -eq "Marketing"
```
**Description:** Includes all users assigned to the Marketing department.

#### IT Department with Job Title Filter
```
user.department -eq "IT" and user.jobTitle -contains "Engineer"
```
**Description:** Includes IT department users with "Engineer" in their job title.

#### New starters in IT Department
```
( user.employeeHireDate -ge (system.now -minus P30D) -and user.employeeHireDate -le system.now ) -and ( user.department -eq "Finance" )
```
**Description:** New starters (within 30d of hire date) will be added to this group, if in the department "Finance".

### Location-Based Groups

#### London Office Users
```
user.city -eq "London" and user.country -eq "United Kingdom"
```
**Description:** Users located in the London office.

#### Remote Workers
```
user.physicalDeliveryOfficeName -eq "Remote" or user.streetAddress -eq null
```
**Description:** Users designated as remote workers or without a physical office address.

### Role-Based Groups

#### Managers
```
user.jobTitle -contains "Manager" or user.jobTitle -contains "Director" or user.jobTitle -contains "VP"
```
**Description:** Users with management titles in their job description.

#### Full Time Employees (FTEs)
```
(user.employeeID -ne null)
```
**Description:** This group is used to enforce the persona "Internals" Conditional Access policies. The group uses employeeID for membership, if this is empty the user is not included in the group.

### Account Type-Based Groups

#### All Member Accounts
```
(user.objectId -ne null) and (user.userType -eq "Member")
```
**Description:** All users with Member account type (excludes Guest users).

## Device-Based Groups

### Operating System Groups

#### Windows 11 Devices
```
device.deviceOSType -eq "Windows" and device.deviceOSVersion -startsWith "10.0.2"
```
**Description:** Devices running Windows 11 (build 2xxxx).

#### iOS Mobile Devices
```
device.deviceOSType -eq "iOS"
```
**Description:** iPhone devices managed by Intune.

#### Windows Servers managed by Security Settings Management (MDE)
```
(device.managementType -eq "MicrosoftSense") and (device.deviceOSType -eq "Windows Server")
```
**Description:** Servers that are onboarded to Security Settings Management will be added to this group.

## Best Practices

### General Guidelines
- Always test dynamic group rules in a non-production environment first
- Use descriptive group names that clearly indicate the membership criteria
- Document the business purpose for each dynamic group
- Regularly review and audit dynamic group memberships
- Consider performance impact of complex rules on large directories

### Rule Writing Tips
- Use consistent attribute naming and casing
- Prefer explicit comparisons over implicit ones
- Use parentheses to group complex logical operations
- Test with a small subset of users/devices before full deployment
- Keep rules as simple as possible while meeting requirements

## Contributing
Feel free to contribute additional examples or improvements to existing rules. Please ensure all examples are tested and documented with clear descriptions.

## License
This collection is provided as-is for educational and reference purposes.
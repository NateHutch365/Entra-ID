Connect-MgGraph -Scopes "User.Read.All","User-LifeCycleInfo.ReadWrite.All"
    #Select-MgProfile -Name "v1.0"

$UserId = "05777779-e538-4fa1-86ff-d6387c6d0796"
    $employeeLeaveDateTime = "2024-10-03T14:59:59Z"
    
    Update-MgUser -UserId $UserId -EmployeeLeaveDateTime $employeeLeaveDateTime

$User = Get-MgUser -UserId $UserId -Property EmployeeLeaveDateTime
    $User.EmployeeLeaveDateTime
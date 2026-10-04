#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'set-h1-compatibility.ps1')

$testId = [Guid]::NewGuid().ToString('N')
$testRoot = 'Software\BBK-H1-Compatibility-Tests\' + $testId
$workspace = Split-Path $PSScriptRoot -Parent
$testDirectory = Join-Path $workspace ('.compatibility-test-' + $testId)
$baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
$assertions = 0
New-Item -ItemType Directory -Path $testDirectory | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw ('Assertion failed: ' + $Message) }
    $script:assertions++
}
function New-Case([string]$Name) {
    @{ BaseKey = $baseKey; RegistryPath = ($testRoot + '\' + $Name); BackupFile = (Join-Path $testDirectory ($Name + '.json')); MachineId = 'test-windows-installation' }
}
function Set-TestValue([hashtable]$Case, [int]$Value) {
    $key = $baseKey.CreateSubKey($Case.RegistryPath)
    try { $key.SetValue('DeviceHackFlags', $Value, [Microsoft.Win32.RegistryValueKind]::DWord) }
    finally { $key.Dispose() }
}
function Get-TestValue([hashtable]$Case) {
    (Get-H1RegistryState -BaseKey $baseKey -RegistryPath $Case.RegistryPath).OriginalValue
}
function Assert-Refused([scriptblock]$Operation, [string]$Message) {
    $refused = $false
    try { & $Operation | Out-Null } catch { $refused = $true }
    Assert-True $refused $Message
}
try {
    $case = New-Case 'Fresh'
    $result = Invoke-H1Compatibility @case
    Assert-True ($result.Action -eq 'Applied') 'Fresh enable succeeds'
    Assert-True ((Get-TestValue $case) -eq 0x20000000) 'Fresh enable sets only the skip-discovery bit'
    $backupHash = (Get-FileHash -LiteralPath $case.BackupFile).Hash
    $result = Invoke-H1Compatibility @case
    Assert-True ($result.Action -eq 'AlreadyApplied') 'Repeated enable is idempotent'
    Assert-True ((Get-FileHash -LiteralPath $case.BackupFile).Hash -eq $backupHash) 'Repeated enable preserves the first backup'
    $result = Invoke-H1Compatibility @case -Restore
    Assert-True ($result.Action -eq 'Restored') 'Restore succeeds'
    Assert-True (!(Get-H1RegistryState -BaseKey $baseKey -RegistryPath $case.RegistryPath).KeyExisted) 'Restore removes newly created empty key'
    $result = Invoke-H1Compatibility @case -Restore
    Assert-True ($result.Action -eq 'AlreadyRestored') 'Repeated restore is idempotent'
    $result = Invoke-H1Compatibility @case
    Assert-True ($result.Action -eq 'Applied') 'Enable after restore succeeds'
    Assert-True ((Get-FileHash -LiteralPath $case.BackupFile).Hash -eq $backupHash) 'Re-enable preserves the first backup'

    $case = New-Case 'ExistingFlags'
    Set-TestValue $case 0x24
    Invoke-H1Compatibility @case | Out-Null
    Assert-True ((Get-TestValue $case) -eq 0x20000024) 'Existing compatibility bits are preserved'
    Invoke-H1Compatibility @case -Restore | Out-Null
    Assert-True ((Get-TestValue $case) -eq 0x24) 'Original DWORD restored exactly'

    $case = New-Case 'HighBit'
    Set-TestValue $case (-2147483644)
    Invoke-H1Compatibility @case | Out-Null
    Assert-True ((Get-TestValue $case) -eq (-1610612732)) 'Unsigned DWORD high bit survives enable'
    Invoke-H1Compatibility @case -Restore | Out-Null
    Assert-True ((Get-TestValue $case) -eq (-2147483644)) 'Unsigned DWORD high bit survives restore'

    $case = New-Case 'ExistingEmptyKey'
    $key = $baseKey.CreateSubKey($case.RegistryPath); $key.Dispose()
    Invoke-H1Compatibility @case | Out-Null
    Invoke-H1Compatibility @case -Restore | Out-Null
    $state = Get-H1RegistryState -BaseKey $baseKey -RegistryPath $case.RegistryPath
    Assert-True ($state.KeyExisted -and !$state.ValueExisted) 'Original empty key is preserved'

    $case = New-Case 'OtherValues'
    Invoke-H1Compatibility @case | Out-Null
    $key = $baseKey.OpenSubKey($case.RegistryPath, $true)
    try { $key.SetValue('KeepMe', 'untouched') } finally { $key.Dispose() }
    Invoke-H1Compatibility @case -Restore | Out-Null
    $key = $baseKey.OpenSubKey($case.RegistryPath, $false)
    try {
        Assert-True ($key.GetValue('KeepMe') -eq 'untouched') 'Unrelated value survives restore'
        Assert-True ($key.GetValueNames() -notcontains 'DeviceHackFlags') 'New compatibility value removed'
    } finally { $key.Dispose() }

    $case = New-Case 'ExternalChange'
    Invoke-H1Compatibility @case | Out-Null
    Set-TestValue $case 0x20000040
    Assert-Refused { Invoke-H1Compatibility @case -Restore } 'Restore refuses external changes'
    Assert-Refused { Invoke-H1Compatibility @case } 'Reapply refuses external changes'
    Assert-True ((Get-TestValue $case) -eq 0x20000040) 'External value remains untouched'

    $case = New-Case 'NoBackup'
    Set-TestValue $case 0x20000000
    Assert-Refused { Invoke-H1Compatibility @case -Restore } 'Missing backup refuses restore'
    Assert-True ((Get-TestValue $case) -eq 0x20000000) 'Missing backup does not alter registry'

    $case = New-Case 'Conflict'
    Set-TestValue $case 0x10000000
    Assert-Refused { Invoke-H1Compatibility @case } 'Force-discovery bit refuses enable'
    Assert-True (!(Test-Path -LiteralPath $case.BackupFile)) 'Refused enable does not create a backup'
    Assert-True ((Get-TestValue $case) -eq 0x10000000) 'Conflicting value remains untouched'

    $case = New-Case 'WhatIf'
    Invoke-H1Compatibility @case -WhatIf | Out-Null
    Assert-True (!(Test-Path -LiteralPath $case.BackupFile)) 'WhatIf does not create a backup'
    Assert-True (!(Get-H1RegistryState -BaseKey $baseKey -RegistryPath $case.RegistryPath).KeyExisted) 'WhatIf does not create a registry key'
    Invoke-H1Compatibility @case | Out-Null
    Invoke-H1Compatibility @case -Restore -WhatIf | Out-Null
    Assert-True ((Get-TestValue $case) -eq 0x20000000) 'WhatIf restore does not change registry'

    $case = New-Case 'WrongMachine'
    Invoke-H1Compatibility @case | Out-Null
    $case.MachineId = 'another-windows-installation'
    Assert-Refused { Invoke-H1Compatibility @case -Restore } 'Backup from another Windows installation refused'

    $case = New-Case 'WrongValueType'
    $key = $baseKey.CreateSubKey($case.RegistryPath)
    try { $key.SetValue('DeviceHackFlags', 'text', [Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
    Assert-Refused { Invoke-H1Compatibility @case } 'Non-DWORD setting refused'

    $case = New-Case 'MalformedBackup'
    Invoke-H1Compatibility @case | Out-Null
    $saved = Get-Content -LiteralPath $case.BackupFile -Raw | ConvertFrom-Json
    $saved.OriginalValue = $true
    $saved | ConvertTo-Json | Set-Content -LiteralPath $case.BackupFile -Encoding UTF8
    Assert-Refused { Invoke-H1Compatibility @case -Restore } 'Invalid original DWORD refused'
    Assert-True ((Get-TestValue $case) -eq 0x20000000) 'Invalid backup does not change registry'

    Write-Host ('PASS: ' + $assertions + ' assertions across 12 scenarios; real H1 configuration was not touched.')
} finally {
    if ($testRoot -ne ('Software\BBK-H1-Compatibility-Tests\' + $testId) -or $testId -notmatch '^[a-f0-9]{32}$') { throw 'Unexpected cleanup target' }
    $baseKey.DeleteSubKeyTree($testRoot, $false)
    $baseKey.Dispose()
    Get-ChildItem -LiteralPath $testDirectory -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $testDirectory
}

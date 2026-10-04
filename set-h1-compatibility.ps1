#Requires -Version 5.1
<#
.SYNOPSIS
Enable or restore the BBK H1 USBSTOR enhanced-storage discovery workaround.
.EXAMPLE
.\set-h1-compatibility.ps1
.EXAMPLE
.\set-h1-compatibility.ps1 -Restore
.EXAMPLE
.\set-h1-compatibility.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$Restore)

$ErrorActionPreference = 'Stop'

function Get-H1RegistryState {
    param([Microsoft.Win32.RegistryKey]$BaseKey, [string]$RegistryPath)
    $key = $BaseKey.OpenSubKey($RegistryPath, $false)
    $keyExisted = $null -ne $key
    $valueExisted = $false
    $original = 0
    if ($key) {
        try {
            $valueExisted = $key.GetValueNames() -contains 'DeviceHackFlags'
            if ($valueExisted) {
                if ($key.GetValueKind('DeviceHackFlags') -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
                    throw 'DeviceHackFlags is not REG_DWORD. No changes were made.'
                }
                $original = [int]$key.GetValue('DeviceHackFlags')
            }
        } finally { $key.Dispose() }
    }
    [pscustomobject]@{ KeyExisted = $keyExisted; ValueExisted = $valueExisted; OriginalValue = $original }
}

function Invoke-H1Compatibility {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][Microsoft.Win32.RegistryKey]$BaseKey,
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][string]$BackupFile,
        [Parameter(Mandatory = $true)][string]$MachineId,
        [switch]$Restore
    )
    $mask = 0x20000000
    $current = Get-H1RegistryState -BaseKey $BaseKey -RegistryPath $RegistryPath
    $backupExists = Test-Path -LiteralPath $BackupFile
    if ($Restore -and !$backupExists) {
        throw 'The original backup is missing. Restore refused; no registry values were changed.'
    }
    if ($backupExists) {
        $saved = Get-Content -LiteralPath $BackupFile -Raw | ConvertFrom-Json
        # Also accept the backup created during the original H1 diagnosis.
        if ($saved.Path -ne $RegistryPath -or
            $saved.KeyExisted -isnot [bool] -or $saved.ValueExisted -isnot [bool] -or
            ($saved.OriginalValue -isnot [int] -and $saved.OriginalValue -isnot [long]) -or
            $saved.OriginalValue -lt [int]::MinValue -or $saved.OriginalValue -gt [int]::MaxValue -or
            (!$saved.KeyExisted -and $saved.ValueExisted) -or
            (!$saved.ValueExisted -and $saved.OriginalValue -ne 0)) {
            throw 'The backup is invalid or belongs to a different registry path. No changes were made.'
        }
        if ($saved.PSObject.Properties.Name -contains 'MachineId') {
            if ($saved.MachineId -ne $MachineId) {
                throw 'The backup belongs to another Windows installation. No changes were made.'
            }
        }
        $original = [int]$saved.OriginalValue
    } else {
        $original = $current.OriginalValue
        $saved = [pscustomobject]@{
            Version = 1
            Path = $RegistryPath
            MachineId = $MachineId
            KeyExisted = $current.KeyExisted
            ValueExisted = $current.ValueExisted
            OriginalValue = $original
            Time = (Get-Date).ToString('o')
        }
    }
    if (!$Restore -and ($original -band 0x10000000)) {
        throw 'An existing force-discovery flag conflicts with this workaround. No changes were made.'
    }
    $applied = $original -bor $mask
    $originalMatches = $current.ValueExisted -eq $saved.ValueExisted -and
        (!$saved.ValueExisted -or $current.OriginalValue -eq $original)
    $appliedMatches = $current.ValueExisted -and $current.OriginalValue -eq $applied
    if ($backupExists -and !$originalMatches -and !$appliedMatches) {
        throw 'DeviceHackFlags changed outside this script. Apply/restore refused to preserve those changes.'
    }
    if ($Restore -and $originalMatches) {
        return [pscustomobject]@{ Action = 'AlreadyRestored'; RegistryPath = $RegistryPath; ReplugRequired = $false }
    }
    if (!$Restore -and $backupExists -and $appliedMatches) {
        return [pscustomobject]@{ Action = 'AlreadyApplied'; RegistryPath = $RegistryPath; Value = ('0x{0:X8}' -f $applied); ReplugRequired = $false }
    }
    $action = if ($Restore) { 'Restore the first saved DeviceHackFlags state' } else { 'Back up the original state and enable H1 compatibility (bit 0x20000000)' }
    if (!$PSCmdlet.ShouldProcess(($BaseKey.Name + '\' + $RegistryPath), $action)) { return }
    # Save the first state before touching the registry; never overwrite it on reapply.
    if (!$backupExists) {
        $saved | ConvertTo-Json | Set-Content -LiteralPath $BackupFile -Encoding UTF8
    }
    if ($Restore) {
        $key = $BaseKey.OpenSubKey($RegistryPath, $true)
        if ($key) {
            try {
                if ($saved.ValueExisted) {
                    $key.SetValue('DeviceHackFlags', $original, [Microsoft.Win32.RegistryValueKind]::DWord)
                } else { $key.DeleteValue('DeviceHackFlags', $false) }
                $empty = $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
            } finally { $key.Dispose() }
            # Preserve a pre-existing key and any unrelated values added later.
            if (!$saved.KeyExisted -and $empty) { $BaseKey.DeleteSubKey($RegistryPath, $false) }
        }
        $result = 'Restored'
        $value = if ($saved.ValueExisted) { '0x{0:X8}' -f $original } else { '(absent)' }
    } else {
        $key = $BaseKey.CreateSubKey($RegistryPath)
        try { $key.SetValue('DeviceHackFlags', $applied, [Microsoft.Win32.RegistryValueKind]::DWord) }
        finally { $key.Dispose() }
        $result = 'Applied'
        $value = '0x{0:X8}' -f $applied
    }
    [pscustomobject]@{ Action = $result; RegistryPath = $RegistryPath; Value = $value; Backup = $BackupFile; ReplugRequired = $true }
}

# Dot-sourcing exposes the functions for tests without running the HKLM entry point.
if ($MyInvocation.InvocationName -eq '.') { return }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or ![Environment]::Is64BitOperatingSystem) {
    throw 'This script targets 64-bit Windows. The verified system is Windows 10 x64; see README.'
}
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (!$WhatIfPreference -and !$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as administrator, then run this script again.'
}
$baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
try {
    $identityKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Cryptography', $false)
    try { $machineId = [string]$identityKey.GetValue('MachineGuid') }
    finally { if ($identityKey) { $identityKey.Dispose() } }
    if (!$machineId) { throw 'Could not identify this Windows installation. No changes were made.' }
    $driverFile = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\drivers\USBSTOR.sys'
    $driver = [Diagnostics.FileVersionInfo]::GetVersionInfo($driverFile)
    $driverVersion = '{0}.{1}.{2}.{3}' -f $driver.FileMajorPart, $driver.FileMinorPart, $driver.FileBuildPart, $driver.FilePrivatePart
    if ($driverVersion -ne '10.0.19041.4355') {
        Write-Warning ('USBSTOR ' + $driverVersion + ' was not validated for this workaround. See README before applying.')
    }
    Invoke-H1Compatibility -BaseKey $baseKey -RegistryPath 'SYSTEM\CurrentControlSet\Control\USBSTOR\07C4A4A5' -BackupFile (Join-Path $PSScriptRoot 'h1-compatibility-original.json') -MachineId $machineId -Restore:$Restore
    if (!$WhatIfPreference) { Write-Host 'Disconnect and reconnect H1 after a change. Keep the original backup beside this script.' }
} finally { $baseKey.Dispose() }

[CmdletBinding(DefaultParameterSetName = "Single", SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Single")]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true, ParameterSetName = "Single")]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true, ParameterSetName = "Single")]
    [string]$VmName,

    [Parameter(Mandatory = $true, ParameterSetName = "Single")]
    [string]$TargetVmSize,

    [Parameter(Mandatory = $true, ParameterSetName = "Batch")]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string]$CsvPath,

    [string]$SnapshotNamePrefix = "pre-bsv2-migration",

    [switch]$SkipPageFileUpdate,

    [switch]$SkipSnapshots,

    [switch]$ReportOnly,

    [switch]$RollbackOnFailure,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Wait-ForVmPowerState {
    param(
        [string]$Rg,
        [string]$Name,
        [string]$ExpectedState,
        [int]$TimeoutSeconds = 900,
        [int]$PollSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $statusVm = Get-AzVM -ResourceGroupName $Rg -Name $Name -Status
        $powerState = ($statusVm.Statuses | Where-Object { $_.Code -like "PowerState/*" } | Select-Object -First 1).DisplayStatus
        if ($powerState -eq $ExpectedState) {
            return
        }

        Write-Host "Waiting for VM '$Name' state '$ExpectedState' (current: '$powerState')..."
        Start-Sleep -Seconds $PollSeconds
    }

    throw "Timeout waiting for VM '$Name' to reach '$ExpectedState'."
}

function New-DiskSnapshot {
    param(
        [System.Object]$Disk,
        [string]$Rg,
        [string]$Location,
        [string]$Prefix,
        [string]$Suffix
    )

    $snapshotName = "$Prefix-$($Disk.Name)-$Suffix"
    Write-Step "Creating snapshot '$snapshotName' from disk '$($Disk.Name)'"
    $snapshotConfig = New-AzSnapshotConfig -SourceUri $Disk.Id -Location $Location -CreateOption Copy
    return New-AzSnapshot -Snapshot $snapshotConfig -SnapshotName $snapshotName -ResourceGroupName $Rg
}

function New-ManagedDiskFromSnapshot {
    param(
        [Microsoft.Azure.Commands.Compute.Automation.Models.PSSnapshot]$Snapshot,
        [string]$Rg,
        [string]$Location,
        [string]$DiskName,
        [string]$SkuName,
        [string[]]$Zones
    )

    $diskConfigParams = @{
        Location         = $Location
        CreateOption     = "Copy"
        SourceResourceId = $Snapshot.Id
        SkuName          = $SkuName
    }

    if ($Zones -and $Zones.Count -gt 0) {
        $diskConfigParams["Zone"] = $Zones
    }

    $diskConfig = New-AzDiskConfig @diskConfigParams
    Write-Step "Creating managed disk '$DiskName' from snapshot '$($Snapshot.Name)'"
    return New-AzDisk -DiskName $DiskName -ResourceGroupName $Rg -Disk $diskConfig
}

function New-VmConfigFromDisks {
    param(
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]$SourceVm,
        [string]$VmSize,
        [string]$NicId,
        [System.Object]$OsDisk,
        [array]$DataDisks
    )

    $vmConfigParams = @{
        VMName = $SourceVm.Name
        VMSize = $VmSize
    }

    if ($SourceVm.Zones -and $SourceVm.Zones.Count -gt 0) {
        $vmConfigParams["Zone"] = $SourceVm.Zones
    }

    $newVmConfig = New-AzVMConfig @vmConfigParams

    if ($SourceVm.AvailabilitySetReference -and $SourceVm.AvailabilitySetReference.Id) {
        $newVmConfig = Set-AzVMAvailabilitySet -VM $newVmConfig -AvailabilitySetId $SourceVm.AvailabilitySetReference.Id
    }

    $osType = $SourceVm.StorageProfile.OsDisk.OsType
    if ($osType -eq "Windows") {
        $newVmConfig = Set-AzVMOSDisk -VM $newVmConfig -ManagedDiskId $OsDisk.Id -CreateOption Attach -Windows
    }
    else {
        $newVmConfig = Set-AzVMOSDisk -VM $newVmConfig -ManagedDiskId $OsDisk.Id -CreateOption Attach -Linux
    }

    $newVmConfig = Add-AzVMNetworkInterface -VM $newVmConfig -Id $NicId -Primary

    foreach ($dd in $DataDisks) {
        $newVmConfig = Add-AzVMDataDisk `
            -VM $newVmConfig `
            -Name $dd.Disk.Name `
            -ManagedDiskId $dd.Disk.Id `
            -Lun $dd.Lun `
            -Caching $dd.Caching `
            -CreateOption Attach
    }

    if ($SourceVm.LicenseType) {
        $newVmConfig.LicenseType = $SourceVm.LicenseType
    }

    if ($SourceVm.Tags) {
        $newVmConfig.Tags = $SourceVm.Tags
    }

    return $newVmConfig
}

function Get-RequiredCsvValue {
    param(
        [pscustomobject]$Row,
        [string]$Name
    )

    $value = [string]$Row.$Name
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "CSV row missing required column '$Name'."
    }

    return $value.Trim()
}

function To-SwitchValue {
    param([string]$InputValue)
    if ([string]::IsNullOrWhiteSpace($InputValue)) {
        return $false
    }

    switch -Regex ($InputValue.Trim().ToLowerInvariant()) {
        "^(1|true|yes|y)$" { return $true }
        default { return $false }
    }
}

function Invoke-VmMigration {
    param(
        [string]$SubId,
        [string]$Rg,
        [string]$Name,
        [string]$NewSize,
        [string]$SnapshotPrefix,
        [bool]$DoSkipPageFileUpdate,
        [bool]$DoSkipSnapshots,
        [bool]$DoReportOnly,
        [bool]$DoRollbackOnFailure,
        [switch]$DoForce
    )

    Write-Step "Validating Azure context for VM '$Name'"
    Set-AzContext -SubscriptionId $SubId | Out-Null

    $vm = Get-AzVM -ResourceGroupName $Rg -Name $Name
    $vmLocation = $vm.Location
    $timestamp = Get-Date -Format "yyyyMMddHHmmss"

    if (-not $vm.StorageProfile.OsDisk.ManagedDisk.Id) {
        throw "Only managed-disk VMs are supported."
    }

    $nicId = ($vm.NetworkProfile.NetworkInterfaces  | Select-Object -First 1).Id
    if (-not $nicId) {
        $nicId = ($vm.NetworkProfile.NetworkInterfaces | Select-Object -First 1).Id
    }
    if (-not $nicId) {
        throw "No NIC found on VM '$Name'."
    }

    $nicName = ($nicId -split "/")[-1]
    $nic = Get-AzNetworkInterface -ResourceGroupName $Rg -Name $nicName
    $ipConfig = $nic.IpConfigurations | Select-Object -First 1
    $currentPrivateIp = $ipConfig.PrivateIpAddress
    if (-not $currentPrivateIp) {
        throw "Could not determine current private IP for VM '$Name'."
    }

    $report = [ordered]@{
        SubscriptionId     = $SubId
        ResourceGroupName  = $Rg
        VmName             = $Name
        CurrentVmSize      = $vm.HardwareProfile.VmSize
        TargetVmSize       = $NewSize
        Location           = $vmLocation
        NicName            = $nic.Name
        PrivateIp          = $currentPrivateIp
        SkipPageFileUpdate = $DoSkipPageFileUpdate
        SkipSnapshots      = $DoSkipSnapshots
        RollbackOnFailure  = $DoRollbackOnFailure
        SnapshotNamePrefix = $SnapshotPrefix
    }

    if ($DoReportOnly) {
        Write-Step "Report-only mode for VM '$Name'"
        [PSCustomObject]$report | Format-List | Out-String | Write-Host
        return
    }

    

    Write-Step "VM '$Name' current private IP: $currentPrivateIp"

    if (-not $DoSkipPageFileUpdate) {
        
        Write-Step "Running in-guest script to move page file to C:"

        $guestScript = @'
    $ErrorActionPreference = "Stop"
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name PagingFiles -Value "C:\pagefile.sys 0 0"
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name ExistingPageFiles -Value @() -ErrorAction SilentlyContinue
    Write-Output "Paging file setting updated to C:\pagefile.sys"
'@

        Invoke-AzVMRunCommand `
            -ResourceGroupName $Rg `
            -Name $Name `
            -CommandId "RunPowerShellScript" `
            -ScriptString $guestScript | Out-Null

        Write-Step "Restarting VM to apply page file change"
        Restart-AzVM -ResourceGroupName $Rg -Name $Name  | Out-Null
        Wait-ForVmPowerState -Rg $Rg -Name $Name -ExpectedState "VM running"
        
    }

    
    Write-Step "Pinning NIC private IP as static to preserve same private IP"
    $ipConfig.PrivateIpAllocationMethod = "Static"
    $ipConfig.PrivateIpAddress = $currentPrivateIp
    Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
    

    
    Write-Step "Stopping and deallocating VM"
    Stop-AzVM -ResourceGroupName $Rg -Name $Name -Force | Out-Null
    Wait-ForVmPowerState -Rg $Rg -Name $Name -ExpectedState "VM deallocated"
    

    $osDisk = Get-AzDisk -ResourceGroupName $Rg -DiskName $vm.StorageProfile.OsDisk.Name
    $dataDisks = @()
    foreach ($d in $vm.StorageProfile.DataDisks) {
        $dataDisks += Get-AzDisk -ResourceGroupName $Rg -DiskName $d.Name
    }

    $newOsDisk = $null
    $newDataDisks = @()

    if (-not $DoSkipSnapshots) {
        Write-Step "Creating snapshots"
        $osSnapshot = New-DiskSnapshot -Disk $osDisk -Rg $Rg -Location $vmLocation -Prefix $SnapshotPrefix -Suffix $timestamp

        $dataSnapshots = @()
        foreach ($d in $dataDisks) {
            $dataSnapshots += New-DiskSnapshot -Disk $d -Rg $Rg -Location $vmLocation -Prefix $SnapshotPrefix -Suffix $timestamp
        }

        $newOsDiskName = "$($osDisk.Name)-bsv2-$timestamp"
        $newOsDisk = New-ManagedDiskFromSnapshot `
            -Snapshot $osSnapshot `
            -Rg $Rg `
            -Location $vmLocation `
            -DiskName $newOsDiskName `
            -SkuName $osDisk.Sku.Name `
            -Zones $osDisk.Zones

        for ($i = 0; $i -lt $dataDisks.Count; $i++) {
            $srcDataDisk = $dataDisks[$i]
            $snap = $dataSnapshots[$i]
            $newDataDiskName = "$($srcDataDisk.Name)-bsv2-$timestamp"
            $newData = New-ManagedDiskFromSnapshot `
                -Snapshot $snap `
                -Rg $Rg `
                -Location $vmLocation `
                -DiskName $newDataDiskName `
                -SkuName $srcDataDisk.Sku.Name `
                -Zones $srcDataDisk.Zones

            $newDataDisks += [PSCustomObject]@{
                Disk    = $newData
                Lun     = ($vm.StorageProfile.DataDisks | Where-Object { $_.Name -eq $srcDataDisk.Name } | Select-Object -First 1).Lun
                Caching = ($vm.StorageProfile.DataDisks | Where-Object { $_.Name -eq $srcDataDisk.Name } | Select-Object -First 1).Caching
            }
        }
    }
    else {
        Write-Step "Skipping snapshots by request; reusing existing disks"
        $newOsDisk = $osDisk
        foreach ($srcDataDisk in $dataDisks) {
            $srcVmData = $vm.StorageProfile.DataDisks | Where-Object { $_.Name -eq $srcDataDisk.Name } | Select-Object -First 1
            $newDataDisks += [PSCustomObject]@{
                Disk    = $srcDataDisk
                Lun     = $srcVmData.Lun
                Caching = $srcVmData.Caching
            }
        }
    }

    if (-not $newOsDisk) {
        throw "No OS disk prepared for new VM."
    }

    $newVmConfig = New-VmConfigFromDisks -SourceVm $vm -VmSize $NewSize -NicId $nic.Id -OsDisk $newOsDisk -DataDisks $newDataDisks
    $rollbackVmConfig = New-VmConfigFromDisks -SourceVm $vm -VmSize $vm.HardwareProfile.VmSize -NicId $nic.Id -OsDisk $osDisk -DataDisks (@($vm.StorageProfile.DataDisks | ForEach-Object {
                $srcDisk = Get-AzDisk -ResourceGroupName $Rg -DiskName $_.Name
                [PSCustomObject]@{
                    Disk    = $srcDisk
                    Lun     = $_.Lun
                    Caching = $_.Caching
                }
            }))

    $removedOriginalVm = $false
    try {
        
        Write-Step "Removing original VM object (NIC and disks are retained)"
        Remove-AzVM -ResourceGroupName $Rg -Name $Name -Force
        $removedOriginalVm = $true
        

        
        Write-Step "Creating replacement VM"
        New-AzVM -ResourceGroupName $Rg -Location $vmLocation -VM $newVmConfig -DisableBginfoExtension | Out-Null
        
    }
    catch {
        Write-Error "Migration failed for VM '$Name': $($_.Exception.Message)"

        if ($DoRollbackOnFailure -and $removedOriginalVm) {
            Write-Step "Attempting rollback: recreating original VM with original size '$($vm.HardwareProfile.VmSize)'"
            try {
                New-AzVM -ResourceGroupName $Rg -Location $vmLocation -VM $rollbackVmConfig -DisableBginfoExtension | Out-Null
                Write-Step "Rollback completed for VM '$Name'"
            }
            catch {
                Write-Error "Rollback failed for VM '$Name': $($_.Exception.Message)"
            }
        }

        throw
    }

    Write-Step "Migration completed"
    Write-Host "VM Name: $Name"
    Write-Host "Old Size: $($vm.HardwareProfile.VmSize)"
    Write-Host "New Size: $NewSize"
    Write-Host "Private IP preserved: $currentPrivateIp"
    Write-Host "NIC reused: $($nic.Name)"
    if (-not $DoSkipSnapshots) {
        Write-Host "Snapshots created with prefix '$SnapshotPrefix' and timestamp '$timestamp'"
    }
}

Write-Step "Validating Azure modules"
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Compute -ErrorAction Stop
Import-Module Az.Network -ErrorAction Stop

if ($PSCmdlet.ParameterSetName -eq "Batch") {
    $rows = Import-Csv -LiteralPath $CsvPath
    if (-not $rows -or $rows.Count -eq 0) {
        throw "CSV file '$CsvPath' has no rows."
    }

    foreach ($row in $rows) {
        $rowSubId = Get-RequiredCsvValue -Row $row -Name "SubscriptionId"
        $rowRg = Get-RequiredCsvValue -Row $row -Name "ResourceGroupName"
        $rowVm = Get-RequiredCsvValue -Row $row -Name "VmName"
        $rowSize = Get-RequiredCsvValue -Row $row -Name "TargetVmSize"

        $rowSnapshotPrefix = if ([string]::IsNullOrWhiteSpace([string]$row.SnapshotNamePrefix)) { $SnapshotNamePrefix } else { [string]$row.SnapshotNamePrefix }
        $rowSkipPage = if ([string]::IsNullOrWhiteSpace([string]$row.SkipPageFileUpdate)) { $SkipPageFileUpdate.IsPresent } else { To-SwitchValue -InputValue ([string]$row.SkipPageFileUpdate) }
        $rowSkipSnap = if ([string]::IsNullOrWhiteSpace([string]$row.SkipSnapshots)) { $SkipSnapshots.IsPresent } else { To-SwitchValue -InputValue ([string]$row.SkipSnapshots) }
        $rowReportOnly = if ([string]::IsNullOrWhiteSpace([string]$row.ReportOnly)) { $ReportOnly.IsPresent } else { To-SwitchValue -InputValue ([string]$row.ReportOnly) }
        $rowRollback = if ([string]::IsNullOrWhiteSpace([string]$row.RollbackOnFailure)) { $RollbackOnFailure.IsPresent } else { To-SwitchValue -InputValue ([string]$row.RollbackOnFailure) }

        Invoke-VmMigration `
            -SubId $rowSubId `
            -Rg $rowRg `
            -Name $rowVm `
            -NewSize $rowSize `
            -SnapshotPrefix $rowSnapshotPrefix `
            -DoSkipPageFileUpdate:$rowSkipPage `
            -DoSkipSnapshots:$rowSkipSnap `
            -DoReportOnly:$rowReportOnly `
            -DoRollbackOnFailure:$rowRollback `
            -DoForce:$Force
    }
}
else {
    Invoke-VmMigration `
        -SubId $SubscriptionId `
        -Rg $ResourceGroupName `
        -Name $VmName `
        -NewSize $TargetVmSize `
        -SnapshotPrefix $SnapshotNamePrefix `
        -DoSkipPageFileUpdate:$SkipPageFileUpdate.IsPresent `
        -DoSkipSnapshots:$SkipSnapshots.IsPresent `
        -DoReportOnly:$ReportOnly.IsPresent `
        -DoRollbackOnFailure:$RollbackOnFailure.IsPresent `
        -DoForce:$Force
}

# Temp Disk SKU Migration Script

This repository contains a PowerShell script to migrate Azure VMs from older B-series SKUs to Bsv2 SKUs while preserving NIC attachment and private IP.

## Files

- `Migrate-BSv1ToBSv2.ps1`: Main migration script.
- `vm-migration.csv`: Example batch input file.

## What The Script Does

For each VM, the script performs the following high-level steps:

1. Validates Azure context and loads VM metadata.
2. Resolves the primary NIC and current private IP.
3. Optionally updates page file settings in-guest (Windows) and restarts the VM.
4. Pins NIC private IP allocation to static using the current IP.
5. Stops and deallocates the VM.
6. Reads OS/data managed disks.
7. Optionally creates snapshots and new managed disks from snapshots.
8. Removes the original VM object (disks and NIC remain).
9. Creates a replacement VM using the target size and selected disks.
10. Optionally attempts rollback if creation fails and rollback is enabled.

## Prerequisites

- PowerShell 7+ (recommended) or Windows PowerShell 5.1.
- Azure PowerShell modules:
  - `Az.Accounts`
  - `Az.Compute`
  - `Az.Network`
- Sufficient Azure RBAC permissions in target subscriptions/resource groups.
- You are signed in to Azure PowerShell (`Connect-AzAccount`).

## Parameters

### Single VM mode (mandatory)

| Parameter | Type | Description |
|---|---|---|
| `-SubscriptionId` | String | Azure subscription ID containing the target VM. |
| `-ResourceGroupName` | String | Resource group name where the VM resides. |
| `-VmName` | String | Name of the VM to migrate. |
| `-TargetVmSize` | String | Target Azure VM SKU size (e.g. `Standard_B2s_v2`). |

### Batch mode (mandatory)

| Parameter | Type | Description |
|---|---|---|
| `-CsvPath` | String | Path to a CSV file containing one row per VM to migrate. The file must exist and be readable. See [CSV Format](#csv-format-batch) for required columns. |

### Optional switches and values

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SnapshotNamePrefix` | String | `pre-bsv2-migration` | Prefix applied to all snapshot and new managed disk names created during migration. Combined with VM name and a timestamp. |
| `-SkipPageFileUpdate` | Switch | `false` | Skip the in-guest script that moves the Windows page file to `C:` before migration. Use this for Linux VMs or when the page file is already on `C:`. |
| `-SkipSnapshots` | Switch | `false` | Skip snapshot and new managed disk creation. The migration reuses existing disks directly. Faster but provides no disk-level rollback point. |
| `-ReportOnly` | Switch | `false` | Print a summary of what would be migrated without making any changes. Useful for pre-migration review. |
| `-RollbackOnFailure` | Switch | `false` | If the new VM creation fails after the original VM has been deleted, automatically attempt to recreate the original VM with its original size and disks. |
| `-Force` | Switch | `false` | Suppresses confirmation prompts for destructive operations (Stop-AzVM, Remove-AzVM). Recommended for unattended/batch runs. |

## CSV Format (Batch)

Required columns:

- `SubscriptionId`
- `ResourceGroupName`
- `VmName`
- `TargetVmSize`

Optional per-row columns (override script-level defaults):

- `SnapshotNamePrefix`
- `SkipPageFileUpdate`
- `SkipSnapshots`
- `ReportOnly`
- `RollbackOnFailure`

Boolean values accepted for row overrides:

- `1`, `true`, `yes`, `y` (case-insensitive) are treated as `true`
- any other value is treated as `false`

## Usage

### 1) Login to Azure

```powershell
Connect-AzAccount
```

### 2) Single VM migration

```powershell
./Migrate-BSv1ToBSv2.ps1 `
  -SubscriptionId "<subscription-guid>" `
  -ResourceGroupName "<resource-group>" `
  -VmName "<vm-name>" `
  -TargetVmSize "Standard_B2s_v2" `
  -RollbackOnFailure `
  -Force
```

### 3) Batch migration from CSV

```powershell
./Migrate-BSv1ToBSv2.ps1 -CsvPath ./vm-migration.csv -Force
```

### 4) Report-only run (no migration actions)

Single VM:

```powershell
./Migrate-BSv1ToBSv2.ps1 `
  -SubscriptionId "<subscription-guid>" `
  -ResourceGroupName "<resource-group>" `
  -VmName "<vm-name>" `
  -TargetVmSize "Standard_B2s_v2" `
  -ReportOnly
```

Batch mode:

```powershell
./Migrate-BSv1ToBSv2.ps1 -CsvPath ./vm-migration.csv -ReportOnly
```

## Recommended Execution Steps (Production)

1. Validate target SKU availability in the VM region.
2. Run in report-only mode and review output.
3. Start with one non-critical VM.
4. Ensure snapshots are enabled for first runs.
5. Enable rollback (`-RollbackOnFailure`) for safer cutover.
6. Migrate batches during maintenance windows.
7. Validate guest OS boot, data disk attachment, and application health.
8. Keep snapshots until post-migration validation is complete.

## Important Notes

- The script supports managed-disk VMs only.
- VM replacement removes and recreates the VM resource object.
- NIC and disks are reused or recreated depending on snapshot settings.
- Private IP preservation depends on NIC static pinning succeeding.
- In-guest page file update is intended for Windows VMs; use `-SkipPageFileUpdate` for Linux VMs.

## Troubleshooting

- `Only managed-disk VMs are supported.`
  - VM is using unmanaged disks. Convert to managed disks first.
- `No NIC found on VM` or private IP resolution failures
  - Verify VM NIC configuration and primary IP config.
- Timeout waiting for power state
  - Validate VM agent/platform operations and retry.
- Replacement VM creation failure
  - Check SKU availability, quota, zone constraints, and disk compatibility.

## Safety Checklist

Before running migration:

- Confirm backup/snapshot strategy.
- Confirm maintenance window and stakeholder approvals.
- Confirm RBAC permissions.
- Confirm target SKU in region and subscription quota.

After migration:

- Confirm VM is running and reachable.
- Confirm private IP and NIC mapping.
- Confirm data disks and app services are healthy.
- Confirm monitoring/alerts are green.

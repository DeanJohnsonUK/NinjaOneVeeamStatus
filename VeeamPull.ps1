<#
.SYNOPSIS
    Enhanced Veeam Status Report for NinjaOne.
    Updated for Veeam v13 licensing (Get-VBRInstalledLicense).

.DESCRIPTION
    Veeam discovery script. Combines system metrics with log-style job history.
    Includes a dedicated table for Backup Repositories (Capacity/Free Space).
    Uses version-aware host selection and de-duplicates job listings.

.PARAMETER cfVeeamJobStatus
    The name of the NinjaOne custom field (WYSIWYG type) used to store the HTML report.

.NOTES
    Author: Dean Johnson
    Version: 5.7 (Fixed Repository 0/0 Space Bug)
#>

[CmdletBinding()]
param (
    [String]$cfVeeamJobStatus = "veeamJobStatus",
    [String]$cfUsbLabel = ""
)

# --- 1. Null-Safe Version Detection & Host Selection ---
$VeeamExe = "C:\Program Files\Veeam\Backup and Replication\Backup\Veeam.Backup.Service.exe"
$VeeamVersion = "0.0.0.0"

if (Test-Path $VeeamExe) {
    $VeeamVersion = (Get-Item $VeeamExe).VersionInfo.ProductVersion
} else {
    $RegKeys = "HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication"
    if (Test-Path $RegKeys) {
        $RegProps = Get-ItemProperty -Path $RegKeys -ErrorAction SilentlyContinue
        if ($RegProps.ProductVersion) { $VeeamVersion = [string]$RegProps.ProductVersion }
        elseif ($RegProps.Version) { $VeeamVersion = [string]$RegProps.Version }
    }
}

$VeeamMajor = [int]($VeeamVersion.Split('.')[0])

if ($VeeamMajor -ge 13) {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $Pwsh = "C:\Program Files\PowerShell\7\pwsh.exe"
        if (Test-Path $Pwsh) {
            & $Pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @PSBoundParameters
            exit $LASTEXITCODE
        }
    }
} else {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $Ps5 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        if (Test-Path $Ps5) {
            & $Ps5 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @PSBoundParameters
            exit $LASTEXITCODE
        }
    }
}

# --- 2. Data Discovery ---
try {
    Import-Module Veeam.Backup.PowerShell -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

    # A. License
    $Lic = [PSCustomObject]@{ Edition = "Unknown"; Expiry = "Unknown"; Usage = ""; DaysRemaining = ""; ColorIcon = "⚪" }
    try {
        $Data = Get-VBRInstalledLicense
        if ($Data) {
            $Lic.Edition = $Data.Edition
            $Lic.Expiry  = $Data.ExpirationDate.ToString("yyyy-MM-dd")
            if ($null -ne $Data.InstancesLimit -and $Data.InstancesLimit -gt 0) { $Lic.Usage = " ($($Data.InstancesUsed)/$($Data.InstancesLimit) Inst)" }
            $DaysRemaining = (New-TimeSpan -Start (Get-Date).Date -End $Data.ExpirationDate.Date).Days
            $Lic.DaysRemaining = $DaysRemaining
            $Lic.ColorIcon = if ($DaysRemaining -gt 15) { "🟢" } elseif ($DaysRemaining -le 7) { "🔴" } else { "🟠" }
        }
    } catch { $Lic.Status = "Check Console" }

    # B. Services
    $ServiceList = Get-Service -Name "VeeamBackupSvc", "*MSSQL*" -ErrorAction SilentlyContinue
    $ServicesDisplay = ($ServiceList | ForEach-Object {
        $Icon = if ($_.Status -eq 'Running') { "🟢" } else { "🔴" }
        "$Icon $($_.Name) ($($_.Status))"
    }) -join "<br>"

    # C. Repository Discovery (FIXED FOR 0/0 BUG)
    $RepoList = Get-VBRBackupRepository | ForEach-Object {
        $TotalGB = 0
        $FreeGB = 0
        
        # New method for v11/v12/v13 to get cached space values
        try {
            $Container = $_.GetContainer()
            $TotalGB = [Math]::Round($Container.CachedTotalSpace.InGigabytes, 1)
            $FreeGB = [Math]::Round($Container.CachedFreeSpace.InGigabytes, 1)
        } catch {
            # Fallback for older versions or specific repo types
            $TotalGB = [Math]::Round($_.Capacity / 1GB, 1)
            $FreeGB = [Math]::Round($_.FreeSpace / 1GB, 1)
        }

        $PctFree = if ($TotalGB -gt 0) { [Math]::Round(($FreeGB / $TotalGB) * 100, 1) } else { 0 }
        $DisplaySpace = if ($TotalGB -eq 0) { "N/A (Object/Cloud)" } else { "$FreeGB GB / $TotalGB GB ($PctFree%)" }
        
        [PSCustomObject]@{ Name = $_.Name; Type = $_.Type; Path = $_.Path; Free = $DisplaySpace }
    }

    # D. Jobs & History
    $AllSessions = Get-VBRBackupSession -WarningAction SilentlyContinue
    $RawJobs = @(Get-VBRJob -ErrorAction SilentlyContinue) + @(Get-VBRComputerBackupJob -ErrorAction SilentlyContinue)
    $UniqueJobs = $RawJobs | Group-Object Name | ForEach-Object { $_.Group[0] }

    $Jobs = foreach ($job in $UniqueJobs) {
        $Sessions = $AllSessions | Where-Object { $_.JobName -eq $job.Name } | Sort-Object CreationTime -Descending | Select-Object -First 5
        $Last = $Sessions | Select-Object -First 1
        
        $HistoryStrings = foreach ($s in $Sessions) {
            $duration = if ($s.EndTime) { ($s.EndTime - $s.CreationTime).ToString("hh\:mm\:ss") } else { "Running" }
            "{0} | {1,-10} | Duration: {2}" -f $s.CreationTime.ToString("yyyy-MM-dd HH:mm"), $s.Result, $duration
        }

        [PSCustomObject]@{
            Name     = $job.Name
            Result   = if ($job.IsScheduleEnabled -eq $false) { "Disabled" } elseif ($Last) { $Last.Result } else { "Never Run" }
            Duration = if ($Last) { if ($Last.EndTime) { ($Last.EndTime - $Last.CreationTime).ToString("hh\:mm\:ss") } else { "Running" } } else { "N/A" }
            Rate     = if ($Sessions.Count -gt 0) { [Math]::Round((($Sessions | Where-Object { $_.Result -eq "Success" }).Count / $Sessions.Count) * 100) } else { 0 }
            History  = if ($HistoryStrings) { $HistoryStrings -join "<br>" } else { "No sessions found." }
        }
    }

    # --- 3. Build HTML (4.8 Layout) ---
    $HeaderStyle = "background-color: #005F4B; color: #ffffff; padding: 8px 12px; text-align: left; font-weight: bold; border: 1px solid #004d3d;"
    
    $Html = "<table style='width:100%; border-collapse: collapse; font-family: Segoe UI, sans-serif; font-size: 12px; border: 1px solid #ddd;'>"
    $Html += "<tr><th colspan='2' style='$HeaderStyle'>VEEAM SYSTEM OVERVIEW</th></tr>"
    $Html += "<tr><td style='padding:8px; border-bottom: 1px solid #eee; width: 50%; line-height: 1.4;'>
                <b>Version:</b> $VeeamVersion<br>
                <b>License:</b> $($Lic.Edition) (Exp: $($Lic.Expiry))$($Lic.Usage) [ $($Lic.ColorIcon) $($Lic.DaysRemaining) Days Remaining ]
              </td>"
    $Html += "<td style='padding:8px; border-bottom: 1px solid #eee; line-height: 1.4;'><b>Critical Services:</b><br>$ServicesDisplay</td></tr></table><br>"
    
    $Html += "<table style='width:100%; border-collapse: collapse; font-family: Segoe UI, sans-serif; font-size: 12px; border: 1px solid #ddd;'>"
    $Html += "<tr><th colspan='4' style='$HeaderStyle'>BACKUP REPOSITORIES</th></tr>"
    $Html += "<tr style='background:#f9f9f9;'><th style='padding:6px; border:1px solid #ddd; text-align:left;'>Repo Name</th><th style='padding:6px; border:1px solid #ddd; text-align:left;'>Type</th><th style='padding:6px; border:1px solid #ddd; text-align:left;'>Path/Host</th><th style='padding:6px; border:1px solid #ddd; text-align:left;'>Capacity (Free / Total)</th></tr>"
    foreach ($r in $RepoList) {
        $Html += "<tr><td style='padding:4px 8px; border:1px solid #eee;'><b>$($r.Name)</b></td><td style='padding:4px 8px; border:1px solid #eee;'>$($r.Type)</td><td style='padding:4px 8px; border:1px solid #eee;'>$($r.Path)</td><td style='padding:4px 8px; border:1px solid #eee;'>$($r.Free)</td></tr>"
    }
    $Html += "</table><br>"

    $Html += "<table style='width:100%; border-collapse: collapse; font-family: Segoe UI, sans-serif; font-size: 12px; border: 1px solid #ddd;'>"
    $Html += "<tr>
                <th style='$HeaderStyle; width:30%;'>Job Name</th>
                <th style='$HeaderStyle; width:10%; text-align:center;'>Last Result</th>
                <th style='$HeaderStyle; width:10%; text-align:center;'>Duration</th>
                <th style='$HeaderStyle; width:15%; text-align:center;'>Success Rate</th>
                <th style='$HeaderStyle; width:35%;'>Session History (Last 5)</th>
              </tr>"
    
    foreach ($j in $Jobs) {
        $StatusIcon = switch ($j.Result) { "Success"{"✅"} "Warning"{"⚠️"} "Failed"{"❌"} "Disabled"{"💤"} Default{"⚪"} }
        $BarColor = if ($j.Rate -eq 100) { "#34b233" } elseif ($j.Rate -gt 70) { "#ff9d00" } else { "#de350b" }
        $BarHtml = "<table style='width: 100px; border-collapse: collapse; border: none; margin: 0 auto;'><tr><td style='height: 8px; padding: 0; border: 1px solid #ccc; background-color: #e0e0e0;'><table style='width: $($j.Rate)%; border-collapse: collapse; border: none;'><tr><td style='height: 8px; background-color: $BarColor; padding: 0; border: none;'></td></tr></table></td></tr></table>"

        $Html += "<tr>
            <td style='padding:4px 8px; border-bottom: 1px solid #eee; width:30%;'><b>$($j.Name)</b></td>
            <td style='padding:4px 8px; border-bottom: 1px solid #eee; width:10%; text-align:center; white-space:nowrap;'>$StatusIcon $($j.Result)</td>
            <td style='padding:4px 8px; border-bottom: 1px solid #eee; width:10%; text-align:center;'>$($j.Duration)</td>
            <td style='padding:4px 8px; border-bottom: 1px solid #eee; width:15%; text-align:center; line-height: 1;'>
                $BarHtml
                <div style='width: 100%; text-align: center; margin-top: 2px;'><b>$($j.Rate)%</b></div>
            </td>
            <td style='padding:4px 8px; border-bottom: 1px solid #eee; width:35%; font-family: Consolas, monospace; font-size: 11px; white-space: pre; line-height: 1.2;'>$($j.History)</td>
        </tr>"
    }
    
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $Html += "<tr><td colspan='5' style='text-align:right; padding:4px 6px; font-size:11px; color:#666;'>Last Updated: $Timestamp</td></tr>"
    $Html += "</table>"

    Set-NinjaProperty -Name $cfVeeamJobStatus -Value $Html
} catch {
    Write-Error "Script Failed: $($_.Exception.Message)"
}
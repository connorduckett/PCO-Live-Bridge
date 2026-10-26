# One-time setup: makes Windows start the PCO Live Bridge every Sunday at 8:00 AM.
# Run once from this folder:   powershell -ExecutionPolicy Bypass -File .\Install-SundayTask.ps1
# Remove later with:           Unregister-ScheduledTask -TaskName 'PCO Live Bridge' -Confirm:$false
param([string]$At = '8:00 AM')

$dir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ps1 = Join-Path $dir 'PcoLiveBridge.ps1'
if (-not (Test-Path $ps1)) { throw "PcoLiveBridge.ps1 not found next to this script ($dir)" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`"" -WorkingDirectory $dir
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $At
$settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 6)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName 'PCO Live Bridge' -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Force `
    -Description 'Follows FOH ProPresenter and drives Planning Center Services Live. Arms 5 min before each service, exits after the last one.' | Out-Null

$t = Get-ScheduledTask -TaskName 'PCO Live Bridge'
$next = (Get-ScheduledTaskInfo -TaskName 'PCO Live Bridge').NextRunTime
Write-Host "Installed scheduled task 'PCO Live Bridge' ($($t.State)). Next run: $next" -ForegroundColor Green
Write-Host "It runs as $env:USERNAME and only while you are signed in on this PC."

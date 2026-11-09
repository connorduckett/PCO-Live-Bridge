# One-time setup: makes Windows start the PCO Live Bridge on service days (several start times + at sign-in).
# Run once from this folder:
#   powershell -ExecutionPolicy Bypass -File .\Install-SundayTask.ps1
#   powershell -ExecutionPolicy Bypass -File .\Install-SundayTask.ps1 -At '7:00 AM','9:00 AM' -Days Saturday,Sunday
#   powershell -ExecutionPolicy Bypass -File .\Install-SundayTask.ps1 -ConfigPath .\config-pm.json -At '3:00 PM'
#   powershell -ExecutionPolicy Bypass -File .\Install-SundayTask.ps1 -Uninstall [-ConfigPath ...]
# Several start times plus "at sign-in": whichever comes first while you're signed in starts it.
# The bridge exits on its own if there's no service today, and only one copy ever runs.
# Each config gets its own task ("PCO Live Bridge" for config.json, "PCO Live Bridge (config-pm)" etc.).
param(
    [string[]]$At = @('7:00 AM', '8:30 AM', '9:15 AM', '10:45 AM'),
    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
    [string[]]$Days = @('Sunday'),
    [string]$ConfigPath = '',
    [switch]$Uninstall
)

$dir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ps1 = Join-Path $dir 'PcoLiveBridge.ps1'
if (-not (Test-Path $ps1)) { throw "PcoLiveBridge.ps1 not found next to this script ($dir)" }

$taskName = 'PCO Live Bridge'
$cfgArg = ''
if ($ConfigPath) {
    $cfgFull = if ([IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath } else { Join-Path $dir $ConfigPath }
    $cfgFull = [IO.Path]::GetFullPath($cfgFull)
    $cfgBase = [IO.Path]::GetFileNameWithoutExtension($cfgFull)
    if ($cfgBase -ne 'config') {
        $taskName = "PCO Live Bridge ($cfgBase)"
        $cfgArg = " -ConfigPath `"$cfgFull`""
    }
} else {
    $cfgFull = Join-Path $dir 'config.json'
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task '$taskName' (if it existed)." -ForegroundColor Green
    return
}

if (-not (Test-Path $cfgFull)) { Write-Warning "$cfgFull not found yet - create it before the first service (see README)." }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`" -OnlyIfServiceToday$cfgArg" -WorkingDirectory $dir
$trigger = @($At | ForEach-Object { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Days -At $_ })
$trigger += New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 7)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Force `
    -Description 'Follows ProPresenter and drives Planning Center Services Live. Arms shortly before each service, exits after the last one.' | Out-Null

$t = Get-ScheduledTask -TaskName $taskName
$next = (Get-ScheduledTaskInfo -TaskName $taskName).NextRunTime
Write-Host "Installed scheduled task '$taskName' ($($t.State)). Next run: $next" -ForegroundColor Green
Write-Host "Starts on $($Days -join ', ') at $($At -join ', ') and whenever you sign in; exits if there's no service that day."
Write-Host "It runs as $env:USERNAME and only while you are signed in on this PC."
Write-Host "Remove it with: .\Install-SundayTask.ps1 -Uninstall$(if ($cfgArg) { " -ConfigPath $ConfigPath" })"

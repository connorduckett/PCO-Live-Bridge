<#
.SYNOPSIS
  Follows the FOH ProPresenter and drives Planning Center Services LIVE to match.

.DESCRIPTION
  Polls ProPresenter's network API (v7.9+) for the active presentation. When the
  operator fires a slide in a new presentation, the bridge matches its name (and
  library path) to an item in today's PCO plan and steps PCO Live forward/back
  until Live is on that item. Unmatched presentations are ignored (Live stays put).

  Handles several service times in one plan (e.g. 9:00 / 11:00): when the
  operator starts the song list over near the next service, the bridge moves
  into the next service time instead of stepping backwards through the first.

.PARAMETER ConfigPath  Path to config.json (default: next to this script)
.PARAMETER DryRun      Log what would happen; never touch PCO Live.
.PARAMETER ListPlan    Print the plan, service times and Live state, then exit.
.PARAMETER TestPP      Print what ProPresenter reports right now, then exit.
.PARAMETER PlanId      Use a specific plan instead of auto-picking today's.

  Works in Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$DryRun,
    [switch]$ListPlan,
    [switch]$ListServiceTypes,
    [switch]$TestPP,
    [switch]$IgnoreSchedule,
    [switch]$OnlyIfServiceToday,
    [string]$PlanId
)

$ErrorActionPreference = 'Stop'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'config.json' }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------------------------------------------------------- config
if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
$Cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

function CfgVal($name, $default) {
    $p = $Cfg.PSObject.Properties[$name]
    if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
    return $default
}

$PPBase          = "http://$(CfgVal 'ProPresenterHost' '127.0.0.1'):$(CfgVal 'ProPresenterPort' 1025)"
$PcoBase         = (CfgVal 'PcoBaseUrl' 'https://api.planningcenteronline.com').TrimEnd('/')
$ServiceTypeId   = "$(CfgVal 'ServiceTypeId' '')"
$PollMs          = [int](CfgVal 'PollIntervalMs' 500)
$DebounceSec     = [double](CfgVal 'DebounceSeconds' 2)
$MinScore        = [int](CfgVal 'MatchThreshold' 60)
$MaxSteps        = [int](CfgVal 'MaxStepsPerMove' 30)
$LeadMin         = [int](CfgVal 'SecondServiceLeadMinutes' 20)
$TakeControl     = [bool](CfgVal 'TakeControlIfNeeded' $true)
$PlanRefreshMin  = [int](CfgVal 'PlanRefreshMinutes' 5)
$ArmBefore       = [int](CfgVal 'ArmMinutesBeforeService' 5)    # -1 = always armed
$ArmAfter        = [int](CfgVal 'ArmMinutesAfterServiceEnd' 30)
$IncludeAddedItems = [bool](CfgVal 'IncludeExcludedItems' $true)
$MaxBackItems    = [int](CfgVal 'MaxBackItems' 2)
$LogDir          = CfgVal 'LogDirectory' (Join-Path $ScriptDir 'logs')
$Rules           = @(CfgVal 'Rules' @())
$IgnorePatterns  = @(CfgVal 'IgnorePresentations' @())
$DisarmedUntil   = $null
$du = CfgVal 'DisarmedUntil' ''
if ($du) { try { $DisarmedUntil = [datetime]::Parse("$du") } catch { throw "DisarmedUntil in config.json is not a valid date/time: $du" } }
function Test-Disarmed { return ($null -ne $DisarmedUntil -and (Get-Date) -lt $DisarmedUntil) }

$CfgName = Split-Path -Leaf $ConfigPath
if ($ServiceTypeId -notmatch '^\d+$' -and -not $ListServiceTypes) {
    throw "ServiceTypeId in $CfgName is missing or not a number ('$ServiceTypeId'). Run with -ListServiceTypes to see yours."
}
$appId  = CfgVal 'PcoAppId' ''
$secret = CfgVal 'PcoSecret' ''
if (-not $appId -or -not $secret -or "$appId$secret" -match 'PASTE_') {
    throw "PcoAppId and PcoSecret (a Planning Center Personal Access Token) must be filled in in $CfgName. See README, Setup step 2."
}

# Check the matching rules up front so a typo fails now, not mid-service.
$ruleNo = 0
foreach ($rule in $Rules) {
    $ruleNo++
    $hasItem   = $rule.PSObject.Properties['item'] -and $rule.item
    $hasHeader = $rule.PSObject.Properties['afterHeader'] -and $rule.afterHeader
    if (-not ($rule.PSObject.Properties['match'] -and $rule.match)) { throw "Rule #$ruleNo in $CfgName has no 'match'." }
    if (-not ($hasItem -or $hasHeader)) { throw "Rule #$ruleNo in $CfgName ('$($rule.match)') needs an 'item' or an 'afterHeader'." }
    foreach ($pat in @($rule.match, $(if ($hasItem) { $rule.item }), $(if ($hasHeader) { $rule.afterHeader }))) {
        if (-not $pat) { continue }
        try { [void][regex]::new("$pat") } catch { throw "Rule #$ruleNo in ${CfgName}: '$pat' is not a valid regex. $($_.Exception.InnerException.Message)" }
    }
}
foreach ($pat in $IgnorePatterns) {
    try { [void][regex]::new("$pat") } catch { throw "IgnorePresentations in ${CfgName}: '$pat' is not a valid regex." }
}
$PcoAuth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($appId):$($secret)"))

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir ("pco-live-bridge_{0:yyyy-MM-dd}.log" -f (Get-Date))

function Log([string]$msg, [string]$level = 'INFO') {
    $line = '{0:HH:mm:ss} [{1}] {2}' -f (Get-Date), $level, $msg
    $color = switch ($level) { 'WARN' {'Yellow'} 'ERROR' {'Red'} 'MOVE' {'Green'} 'DRY' {'Cyan'} default {'Gray'} }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $LogFile -Value $line } catch {}
}

# ---------------------------------------------------------------- HTTP helpers
function Get-StatusCode($err) {
    try { return [int]$err.Exception.Response.StatusCode } catch { return 0 }
}

function Invoke-Pco([string]$Method, [string]$Path, $Body = $null) {
    $uri = if ($Path -match '^https?://') { $Path } else { "$PcoBase$Path" }
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $irm = @{ Method = $Method; Uri = $uri; Headers = @{ Authorization = $PcoAuth }; ContentType = 'application/json'; TimeoutSec = 15 }
            if ($null -ne $Body) { $irm.Body = ($Body | ConvertTo-Json -Depth 8 -Compress) }
            return Invoke-RestMethod @irm
        } catch {
            $code = Get-StatusCode $_
            if ($code -eq 429 -or $code -ge 500 -or $code -eq 0) {
                Log "PCO $Method $Path -> $code, retry $attempt" 'WARN'
                Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 8)); continue
            }
            $body = ""; try { if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $body = " | " + ($_.ErrorDetails.Message -replace "\s+", " ") } } catch {}
            $e = New-Object System.Exception("PCO $Method $uri failed ($code): $($_.Exception.Message)$body")
            $e.Data['StatusCode'] = $code
            throw $e
        }
    }
    throw "PCO $Method $Path failed after retries"
}

function Get-PcoAll([string]$Path) {
    $out = @(); $next = $Path
    while ($next) {
        $r = Invoke-Pco GET $next
        $out += @($r.data)
        $next = $null
        if ($r.links -and $r.links.PSObject.Properties['next'] -and $r.links.next) { $next = $r.links.next }
    }
    return $out
}

function Invoke-PP([string]$Path) {
    try { return Invoke-RestMethod -Method GET -Uri "$PPBase$Path" -TimeoutSec 3 }
    catch { return $null }
}

# ---------------------------------------------------------------- matching
function Normalize([string]$s) {
    if (-not $s) { return '' }
    $s = $s.ToLowerInvariant()
    $s = $s -replace '\.pro$', ''
    $s = $s -replace '\([^)]*\)|\[[^\]]*\]', ' '        # (Live), [Key of G]
    $s = $s -replace '^\s*\d+\s*[-_.)]\s*', ''           # "03 - Song"
    $s = $s -replace '&', ' and '
    $s = $s -replace "[\u2019']", ''
    $s = $s -replace '[^a-z0-9]+', ' '
    return ($s -replace '\s+', ' ').Trim()
}

function Get-MatchScore([string]$a, [string]$b) {
    $x = Normalize $a; $y = Normalize $b
    if (-not $x -or -not $y) { return 0 }
    if ($x -eq $y) { return 100 }
    if (($x.Length -ge 4 -and $y.Contains($x)) -or ($y.Length -ge 4 -and $x.Contains($y))) { return 85 }
    $tx = @($x.Split(' ') | Where-Object { $_.Length -gt 1 } | Select-Object -Unique)
    $ty = @($y.Split(' ') | Where-Object { $_.Length -gt 1 } | Select-Object -Unique)
    if ($tx.Count -eq 0 -or $ty.Count -eq 0) { return 0 }
    $inter = @($tx | Where-Object { $ty -contains $_ }).Count
    $union = @($tx + $ty | Select-Object -Unique).Count
    return [int](75 * $inter / $union)
}

# ---------------------------------------------------------------- plan state
$Script:Plan = $null          # plan object
$Script:Items = @()           # non-header items, ordered: @{Id;Title;Type;Header;Ord}
$Script:ServiceTimes = @()    # ordered service plan_times: @{Id;Start;End;Idx}
$Script:MyPersonId = $null
$Script:LiveSelf = $null
$Script:LastLiveRaw = $null
$Script:SaidControl = $false
$Script:ServiceDoneMsg = $false
$Script:TooFarBackMsg = $false
$Script:Skipped = @{}   # "itemId|planTimeId" that Live skips (item excluded from that service)
$Script:PlanLoadedAt = [datetime]::MinValue

function Select-Plan {
    if ($PlanId) { return (Invoke-Pco GET "/services/v2/service_types/$ServiceTypeId/plans/$PlanId").data }
    $today = (Get-Date).Date
    $plans = (Invoke-Pco GET "/services/v2/service_types/$ServiceTypeId/plans?filter=future&order=sort_date&per_page=3").data
    $past  = (Invoke-Pco GET "/services/v2/service_types/$ServiceTypeId/plans?filter=past&order=-sort_date&per_page=1").data
    foreach ($p in @($past) + @($plans)) {
        if ($p -and ([datetime]$p.attributes.sort_date).ToLocalTime().Date -eq $today) { return $p }
    }
    if ($plans) {
        Log "No plan dated today; using next upcoming plan ($($plans[0].attributes.dates))" 'WARN'
        return $plans[0]
    }
    throw "No plans found for service type $ServiceTypeId"
}

function Load-Plan {
    $Script:Plan = Select-Plan
    $pid_ = $Script:Plan.id
    $raw = Get-PcoAll "/services/v2/service_types/$ServiceTypeId/plans/$pid_/items?per_page=100&order=sequence"
    $header = ''; $ord = 0; $list = @()
    foreach ($i in ($raw | Sort-Object { [int]$_.attributes.sequence })) {
        if ($i.attributes.item_type -eq 'header') { $header = $i.attributes.title; continue }
        $list += [pscustomobject]@{ Id = "$($i.id)"; Title = $i.attributes.title; Type = $i.attributes.item_type; Header = $header; Ord = $ord }
        $ord++
    }
    $Script:Items = $list
    $times = Get-PcoAll "/services/v2/service_types/$ServiceTypeId/plans/$pid_/plan_times?per_page=100"
    $idx = 0
    $Script:ServiceTimes = @($times | Where-Object { $_.attributes.time_type -eq 'service' } |
        Sort-Object { [datetime]$_.attributes.starts_at } | ForEach-Object {
            [pscustomobject]@{ Id = "$($_.id)"; Start = ([datetime]$_.attributes.starts_at).ToLocalTime(); End = ([datetime]$_.attributes.ends_at).ToLocalTime(); Idx = ($idx++) }
        })
    $Script:PlanLoadedAt = Get-Date
}

function Get-MyPersonId {
    if (-not $Script:MyPersonId) { $Script:MyPersonId = "$((Invoke-Pco GET '/services/v2/me').data.id)" }
    return $Script:MyPersonId
}

# Returns @{ LiveId; ItemId; PlanTimeId; ControllerId; Started }
function Get-LiveState {
    $p = $Script:Plan.id
    $r = Invoke-Pco GET "/services/v2/service_types/$ServiceTypeId/plans/$p/live?include=current_item_time,controller"
    $Script:LastLiveRaw = $r
    try { if ($r.data.links -and $r.data.links.self) { $Script:LiveSelf = "$($r.data.links.self)".TrimEnd('/') } } catch {}
    $state = [ordered]@{ LiveId = "$($r.data.id)"; ItemId = $null; PlanTimeId = $null; ControllerId = $null; Started = $false }
    $rel = $r.data.relationships
    if ($rel.controller -and $rel.controller.data) { $state.ControllerId = "$($rel.controller.data.id)" }
    if ($rel.current_item_time -and $rel.current_item_time.data) {
        $citId = "$($rel.current_item_time.data.id)"
        $cit = @($r.included) | Where-Object { $_.type -eq 'ItemTime' -and "$($_.id)" -eq $citId } | Select-Object -First 1
        if ($cit) {
            $state.ItemId     = "$($cit.relationships.item.data.id)"
            $state.PlanTimeId = "$($cit.relationships.plan_time.data.id)"
            $state.Started    = $true
        }
    }
    return [pscustomobject]$state
}

# Linear position across (service time, item) so we know which way to step.
function Get-Position($planTimeId, $itemId) {
    $st = $Script:ServiceTimes | Where-Object { $_.Id -eq "$planTimeId" } | Select-Object -First 1
    $it = $Script:Items | Where-Object { $_.Id -eq "$itemId" } | Select-Object -First 1
    if (-not $it) { return $null }
    $stIdx = if ($st) { $st.Idx } else { -1 }
    return ($stIdx * 1000) + $it.Ord
}

function Get-LiveActionBase($live) {
    if ($Script:LiveSelf) { return $Script:LiveSelf }
    return "/services/v2/service_types/$ServiceTypeId/plans/$($Script:Plan.id)/live"
}

function Ensure-Control($live) {
    $me = Get-MyPersonId
    if ($live.ControllerId -eq $me) { if (-not $Script:SaidControl) { Log "Already controlling PCO Live as person $me"; $Script:SaidControl = $true }; return $true }
    if (-not $TakeControl) {
        Log "PCO Live is controlled by person $($live.ControllerId); TakeControlIfNeeded=false, not moving." 'WARN'
        return $false
    }
    Log "Taking control of PCO Live (was: $(if ($live.ControllerId) { $live.ControllerId } else { 'nobody' }))"
    Invoke-Pco POST "$(Get-LiveActionBase $live)/toggle_control" | Out-Null
    return $true
}

function Step-Live($live, [string]$direction) {
    $action = if ($direction -eq 'next') { 'go_to_next_item' } else { 'go_to_previous_item' }
    Invoke-Pco POST "$(Get-LiveActionBase $live)/$action" | Out-Null
}

# ---------------------------------------------------------------- deciding the target
function Find-Candidates([string]$ppName, [string]$ppPath, [string]$ppPlaylistItem) {
    $hay = "$ppName | $ppPath"
    foreach ($rule in $Rules) {
        if ($rule.match -and $hay -match $rule.match) {
            $hits = @()
            if ($rule.PSObject.Properties['item'] -and $rule.item) {
                $hits = @($Script:Items | Where-Object { $_.Title -match $rule.item })
            } elseif ($rule.PSObject.Properties['afterHeader'] -and $rule.afterHeader) {
                $hits = @($Script:Items | Where-Object { $_.Header -match $rule.afterHeader } | Select-Object -First 1)
            }
            if ($hits.Count) { return @{ Items = $hits; Why = "rule '$($rule.match)'" } }
        }
    }
    $best = 0; $hits = @()
    foreach ($it in $Script:Items) {
        $s = [Math]::Max((Get-MatchScore $ppName $it.Title), (Get-MatchScore $ppPlaylistItem $it.Title))
        if ($s -gt $best) { $best = $s; $hits = @($it) } elseif ($s -eq $best -and $s -gt 0) { $hits += $it }
    }
    if ($best -ge $MinScore) { return @{ Items = $hits; Why = "name match $best" } }
    return $null
}

function Resolve-Target($candidates, $live) {
    $now = Get-Date
    $curPos = if ($live.Started) { Get-Position $live.PlanTimeId $live.ItemId } else { -1 }
    $curSt  = $Script:ServiceTimes | Where-Object { $_.Id -eq $live.PlanTimeId } | Select-Object -First 1
    if (-not $curSt) {
        # Not started (or on a non-service time): pick the service time we're in or next up.
        $curSt = $Script:ServiceTimes | Where-Object { $now -lt $_.End } | Select-Object -First 1
        if (-not $curSt) { $curSt = $Script:ServiceTimes | Select-Object -Last 1 }
    }
    $nextSt = $Script:ServiceTimes | Where-Object { $_.Idx -eq ($curSt.Idx + 1) } | Select-Object -First 1

    $options = @()
    foreach ($it in $candidates) {
        $pos = ($curSt.Idx * 1000) + $it.Ord
        if ($nextSt -and $live.Started -and $pos -lt $curPos -and $now -ge $curSt.End -and $now -ge $nextSt.Start.AddMinutes(-$LeadMin)) {
            # Operator went back to an earlier item, the current service's scheduled end has passed
            # and the next service is close: this is the restart for the next service, move into it.
            $options += [pscustomobject]@{ Item = $it; St = $nextSt; Pos = ($nextSt.Idx * 1000) + $it.Ord }
        } else {
            $options += [pscustomobject]@{ Item = $it; St = $curSt; Pos = $pos }
        }
    }
    # Once Live has reached the last item of a service (e.g. Dismissal), that service is finished:
    # never pull it backwards (post-service announcement loops would otherwise rewind it).
    if ($live.Started -and $curSt -and $live.PlanTimeId -eq $curSt.Id) {
        $lastItem = $Script:Items | Select-Object -Last 1
        if ($lastItem -and $live.ItemId -eq $lastItem.Id) {
            $options = @($options | Where-Object { $_.Pos -gt $curPos })
            if ($options.Count -eq 0) { $Script:ServiceDoneMsg = $true; return $null }
        }
    }
    # Don't rewind far: a song repeated later (e.g. an earlier worship song reused as the invitation)
    # would otherwise drag Live back through the service. Small step-backs (operator went back a song) are fine.
    if ($live.Started -and $MaxBackItems -ge 0) {
        $before = $options.Count
        $options = @($options | Where-Object { -not ($_.Pos -lt $curPos -and ($curPos - $_.Pos) -gt $MaxBackItems) })
        if ($options.Count -eq 0 -and $before -gt 0) { $Script:TooFarBackMsg = $true; return $null }
    }
    # Drop items Live has already shown it skips in that service (excluded in PCO for that time).
    $options = @($options | Where-Object { -not $Script:Skipped.ContainsKey("$($_.Item.Id)|$($_.St.Id)") })
    if ($options.Count -eq 0) { return $null }
    # Prefer the nearest occurrence at/after the current position, else the nearest behind it.
    $fwd = $options | Where-Object { $_.Pos -ge $curPos } | Sort-Object Pos | Select-Object -First 1
    if ($fwd) { return $fwd }
    return ($options | Sort-Object Pos -Descending | Select-Object -First 1)
}

# If an item is turned off ("excluded") for the target service time - e.g. an invitation song added
# during the first service - turn it on for that time so PCO Live will land on it. Returns $true if it is included.
function Ensure-ItemIncluded($target) {
    if (-not $IncludeAddedItems) { return $true }
    $base = "/services/v2/service_types/$ServiceTypeId/plans/$($Script:Plan.id)/items/$($target.Item.Id)/item_times"
    try {
        $times = @((Invoke-Pco GET $base).data)
        $it = $times | Where-Object { $_.relationships.plan_time.data -and "$($_.relationships.plan_time.data.id)" -eq $target.St.Id } | Select-Object -First 1
        if (-not $it) { return $true }   # can't tell; let the move logic handle it
        if (-not $it.attributes.exclude) { return $true }
        if ($DryRun) { Log "Would turn ON '$($target.Item.Title)' for the $($target.St.Start.ToString('h:mm tt')) service (it is excluded)" 'DRY'; return $true }
        Invoke-Pco PATCH "$base/$($it.id)" @{ data = @{ type = 'ItemTime'; id = "$($it.id)"; attributes = @{ exclude = $false } } } | Out-Null
        Log "Turned ON '$($target.Item.Title)' for the $($target.St.Start.ToString('h:mm tt')) service (was excluded) so Live can time it" 'MOVE'
        $Script:Skipped.Remove("$($target.Item.Id)|$($target.St.Id)")
        return $true
    } catch {
        Log "Couldn't check/turn on '$($target.Item.Title)' for that service: $($_.Exception.Message)" 'WARN'
        return $true
    }
}

function Move-LiveTo($target) {
    $live = Get-LiveState
    if ($live.Started -and $live.ItemId -eq $target.Item.Id -and $live.PlanTimeId -eq $target.St.Id) {
        Log "PCO Live already on '$($target.Item.Title)'"; return
    }
    $label = "'$($target.Item.Title)' (service $($target.St.Start.ToString('h:mm tt')))"
    if ($DryRun) { Log "Would move PCO Live to $label" 'DRY'; return }
    if (Test-Disarmed) { Log "DISARMED until $($DisarmedUntil.ToString('ddd M/d h:mm tt')) - would move PCO Live to $label" 'DRY'; return }
    if (-not (Ensure-Control $live)) { return }
    Ensure-ItemIncluded $target | Out-Null

    $steps = 0; $lastPos = $null; $stuck = 0; $firstDir = $null
    while ($steps -lt $MaxSteps) {
        $curPos = if ($live.Started) { Get-Position $live.PlanTimeId $live.ItemId } else { -1 }
        if ($null -eq $curPos) { $curPos = -1 }   # e.g. on a rehearsal time: walk forward
        if ($live.Started -and $live.ItemId -eq $target.Item.Id -and $live.PlanTimeId -eq $target.St.Id) { break }
        $dir = if ($target.Pos -gt $curPos) { 'next' } else { 'previous' }
        if ($null -eq $firstDir) { $firstDir = $dir }
        elseif ($dir -ne $firstDir) {
            # We stepped past the target without landing on it: Live skips this item in this service
            # (it's excluded for this time in PCO). Undo the overshoot and remember not to chase it again.
            $Script:Skipped["$($target.Item.Id)|$($target.St.Id)"] = $true
            Step-Live $live $dir; $steps++; $live = Get-LiveState
            Log "'$($target.Item.Title)' is skipped by PCO Live in the $($target.St.Start.ToString('h:mm tt')) service (excluded from that time) - left Live where it was" 'WARN'
            return
        }
        try { Step-Live $live $dir }
        catch {
            $code = $_.Exception.Data['StatusCode']
            if (($code -eq 403 -or $code -eq 422) -and $TakeControl) {
                Log "Live refused move ($code); re-checking control" 'WARN'
                $Script:MyPersonId = $null
                if (-not (Ensure-Control (Get-LiveState))) { return }
                Step-Live $live $dir
            } else { throw }
        }
        $steps++
        $live = Get-LiveState
        $newPos = Get-Position $live.PlanTimeId $live.ItemId
        if ($newPos -eq $lastPos) { $stuck++; if ($stuck -ge 2) { Log "Live stopped moving at position $newPos; giving up on this move" 'WARN'; break } } else { $stuck = 0 }
        $lastPos = $newPos
    }
    if ($live.ItemId -eq $target.Item.Id -and $live.PlanTimeId -eq $target.St.Id) { Log "PCO Live -> $label ($steps step$(if ($steps -ne 1) {'s'}))" 'MOVE' }
    else { Log "Stopped after $steps steps without reaching $label" 'WARN' }
}

# ---------------------------------------------------------------- ProPresenter read
function Get-PPActive {
    $a = Invoke-PP '/v1/presentation/active'
    if (-not $a -or -not $a.presentation) { return $null }
    $p = $a.presentation
    $pl = Invoke-PP '/v1/playlist/active'
    $plItem = ''
    if ($pl -and $pl.presentation -and $pl.presentation.item) { $plItem = $pl.presentation.item.name }
    return [pscustomobject]@{
        Uuid = "$($p.id.uuid)"; Name = "$($p.id.name)"; Path = "$($p.presentation_path)"; PlaylistItem = "$plItem"
    }
}

# ---------------------------------------------------------------- service windows
# Armed from ArmMinutesBeforeService before each service time until ArmMinutesAfterServiceEnd after it.
function Get-ArmState {
    $now = Get-Date
    if ($IgnoreSchedule -or $ArmBefore -lt 0) { return [pscustomobject]@{ Armed = $true; St = $null; Next = $null } }
    foreach ($st in $Script:ServiceTimes) {
        if ($now -ge $st.Start.AddMinutes(-$ArmBefore) -and $now -le $st.End.AddMinutes($ArmAfter)) {
            return [pscustomobject]@{ Armed = $true; St = $st; Next = $null }
        }
    }
    $next = $Script:ServiceTimes | Where-Object { $now -lt $_.Start.AddMinutes(-$ArmBefore) } | Select-Object -First 1
    return [pscustomobject]@{ Armed = $false; St = $null; Next = $next }
}

function Format-ArmTime($st) {
    if (-not $st) { return 'no more services in this plan' }
    $t = $st.Start.AddMinutes(-$ArmBefore)
    if ($t.Date -eq (Get-Date).Date) { return $t.ToString('h:mm tt') }
    return $t.ToString('ddd M/d h:mm tt')
}

# ---------------------------------------------------------------- entry points
if ($ListServiceTypes) {
    $types = Get-PcoAll '/services/v2/service_types?per_page=100&order=name'
    Write-Host 'Planning Center service types (put the ID in config.json as ServiceTypeId):' -ForegroundColor Cyan
    foreach ($t in $types) { Write-Host ("  {0,-10} {1}" -f $t.id, $t.attributes.name) }
    exit 0
}

if ($TestPP) {
    $v = Invoke-PP '/version'
    if (-not $v) { Log "No response from ProPresenter at $PPBase. Check ProPresenter > Settings > Network > Enable Network." 'ERROR'; exit 1 }
    Log "ProPresenter: $($v.name) $($v.host_description)"
    $a = Get-PPActive
    if ($a) { Log "Active presentation: '$($a.Name)'  path: $($a.Path)  playlist item: '$($a.PlaylistItem)'" }
    else { Log 'No active presentation (fire a slide and run again).' }
    exit 0
}

# Only one live bridge at a time (scheduled task + a double-click would otherwise fight over PCO Live).
$Script:Mutex = $null
if (-not $DryRun -and -not $TestPP -and -not $ListPlan) {
    $Script:Mutex = New-Object System.Threading.Mutex($false, 'Local\PcoLiveBridge')
    $got = $false
    try { $got = $Script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { Log 'Another PCO Live Bridge is already running on this PC - this copy is exiting.' 'WARN'; exit 0 }
}

Log "PCO Live Bridge starting  (ProPresenter $PPBase, service type $ServiceTypeId$(if ($DryRun) {', DRY RUN'}))"
Load-Plan
if ($OnlyIfServiceToday) {
    $today = (Get-Date).Date
    if (-not ($Script:ServiceTimes | Where-Object { $_.Start.Date -eq $today })) {
        Log 'No service in this plan today - exiting (started with -OnlyIfServiceToday).'
        exit 0
    }
}
if (Test-Disarmed) { Log "Bridge is DISARMED until $($DisarmedUntil.ToString('dddd M/d h:mm tt')) (DisarmedUntil in config.json) - it will only log, not move PCO Live" 'WARN' }
Log "Plan: $($Script:Plan.attributes.dates) '$($Script:Plan.attributes.title)'  id $($Script:Plan.id)  - $($Script:Items.Count) items, $($Script:ServiceTimes.Count) service times"

if ($ListPlan) {
    foreach ($st in $Script:ServiceTimes) { Log ("Service time {0}: {1:h:mm tt} - {2:h:mm tt}" -f $st.Idx, $st.Start, $st.End) }
    foreach ($it in $Script:Items) { Log ("  {0,2}. [{1,-5}] {2}   (under: {3})" -f $it.Ord, $it.Type, $it.Title, $it.Header) }
    $live = Get-LiveState
    $cur = $Script:Items | Where-Object { $_.Id -eq $live.ItemId } | Select-Object -First 1
    try { $dbg = Join-Path $LogDir 'live-debug.json'; $Script:LastLiveRaw | ConvertTo-Json -Depth 12 | Set-Content -Path $dbg; Log "Saved raw Live response to $dbg" } catch {}
    Log "Live action base: $(Get-LiveActionBase $live)"
    Log "Live: started=$($live.Started) current='$(if ($cur) { $cur.Title })' controller=$($live.ControllerId) me=$(Get-MyPersonId)"
    exit 0
}

$lastUuid = $null; $pendingUuid = $null; $pendingSince = $null; $ppDown = $false
$wasArmed = $null
$heldUuid = $null; $heldSince = $null   # presentation held back because the service had finished
if ($ArmBefore -ge 0 -and -not $IgnoreSchedule) { Log "Schedule: arms $ArmBefore min before each service, disarms $ArmAfter min after its scheduled end" }

while ($true) {
    try {
        if (((Get-Date) - $Script:PlanLoadedAt).TotalMinutes -ge $PlanRefreshMin) {
            $before = $Script:Items.Count; Load-Plan
            if ($Script:Items.Count -ne $before) { Log "Plan refreshed: $($Script:Items.Count) items" }
        }

        $arm = Get-ArmState
        if ($arm.Armed -ne $wasArmed) {
            if ($arm.Armed) {
                if ($arm.St) { Log ("ARMED for the {0:h:mm tt} service" -f $arm.St.Start) 'MOVE' }
                $lastUuid = $null; $pendingUuid = $null   # re-evaluate whatever is on screen right now
            } else {
                if ($arm.Next) { Log "Waiting - will arm at $(Format-ArmTime $arm.Next). ProPresenter changes are ignored until then$(if ($DryRun) {' (dry run still logs them)'})." 'WARN' }
                else { Log 'No more services in this plan.' 'WARN' }
            }
            $wasArmed = $arm.Armed
        }

        if (-not $arm.Armed -and -not $arm.Next -and -not $DryRun -and $Script:ServiceTimes.Count -gt 0 -and
            (Get-Date) -gt ($Script:ServiceTimes | Select-Object -Last 1).End.AddMinutes($ArmAfter)) {
            Log 'Last service window for this plan is over - PCO Live Bridge exiting.' 'MOVE'
            exit 0
        }

        $a = Get-PPActive
        if (-not $a) {
            if (-not $ppDown -and -not (Invoke-PP '/version')) { Log "Lost ProPresenter at $PPBase" 'WARN'; $ppDown = $true }
        } else {
            if ($ppDown) { Log 'ProPresenter is back'; $ppDown = $false }
            # A loop that came up a few minutes before the next service's handoff window: look at it again every 30 s.
            if ($heldUuid -and $a.Uuid -eq $heldUuid -and $a.Uuid -eq $lastUuid -and ((Get-Date) - $heldSince).TotalSeconds -ge 30) {
                $lastUuid = $null; $pendingUuid = $a.Uuid; $pendingSince = (Get-Date).AddSeconds(-$DebounceSec)
            }
            if ($a.Uuid -ne $lastUuid) {
                if ($a.Uuid -ne $pendingUuid) { $pendingUuid = $a.Uuid; $pendingSince = Get-Date }
                elseif (((Get-Date) - $pendingSince).TotalSeconds -ge $DebounceSec) {
                    $lastUuid = $a.Uuid
                    $ignored = $false
                    foreach ($pat in $IgnorePatterns) { if ("$($a.Name) | $($a.Path)" -match $pat) { $ignored = $true } }
                    if ($ignored) { Log "ProPresenter: '$($a.Name)' (ignored)" }
                    elseif (-not $arm.Armed -and -not $DryRun) { Log "ProPresenter: '$($a.Name)' - not armed yet (arms at $(Format-ArmTime $arm.Next)), PCO Live untouched" }
                    else {
                        $c = Find-Candidates $a.Name $a.Path $a.PlaylistItem
                        if (-not $c) {
                            # Maybe it was just added to the plan (e.g. the invitation song): reload and try once more.
                            try { Load-Plan } catch {}
                            $c = Find-Candidates $a.Name $a.Path $a.PlaylistItem
                            if ($c) { Log "Found '$($a.Name)' after reloading the plan ($($Script:Items.Count) items)" }
                        }
                        if (-not $c) { Log "ProPresenter: '$($a.Name)' - no plan match, PCO Live stays put" 'WARN' }
                        else {
                            Log "ProPresenter: '$($a.Name)' -> $($c.Why)"
                            $Script:ServiceDoneMsg = $false; $Script:TooFarBackMsg = $false
                            $target = Resolve-Target $c.Items (Get-LiveState)
                            $wasHeld = ($heldUuid -eq $a.Uuid)
                            $heldUuid = $null
                            if ($target) { Move-LiveTo $target }
                            elseif ($Script:TooFarBackMsg) { Log "'$($a.Name)' is earlier in the plan than where Live is - not rewinding (add it again later in the PCO plan if it's being reused)" 'WARN' }
                            elseif ($Script:ServiceDoneMsg) {
                                if (-not $wasHeld) { Log "Service is finished (Live is on the last item) - not rewinding PCO Live for '$($a.Name)'" }
                                $heldUuid = $a.Uuid; $heldSince = Get-Date
                            }
                            else { Log "'$($a.Name)' is excluded from this service in PCO - PCO Live stays put" 'WARN' }
                        }
                    }
                }
            }
        }
    } catch {
        Log $_.Exception.Message 'ERROR'
        Start-Sleep -Seconds 3
    }
    Start-Sleep -Milliseconds $PollMs
}

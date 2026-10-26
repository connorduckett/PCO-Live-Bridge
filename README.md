# PCO Live Bridge

Drives **Planning Center Services Live** from the **FOH ProPresenter** on Sunday mornings, so nobody has to sit and run Live by hand.

It polls ProPresenter's network API for the active presentation. When the operator fires a new presentation, the bridge matches it to an item in today's plan and steps PCO Live to that item.

Runs on Windows PowerShell 5.1 or PowerShell 7. Nothing to install.

## How a Sunday runs

| Time | What the bridge does |
|---|---|
| Sunday start (Task Scheduler) | Opens, loads today's plan, waits. Rehearsal clicks are logged but Live is untouched |
| 5 min before each service time in PCO | Arms and moves Live to whatever is on screen |
| During the service | Follows FOH: every new presentation moves Live to the matching item |
| Between services | Firing the 11:00 opener after the 9:30's scheduled end moves Live into the 11:00 service |
| 30 min after the last service's scheduled end | Exits |

## Matching

- **Songs:** matched by name. Case, punctuation, `(Live)`, `[G]` and leading `03 -` are ignored.
- **Other items:** handled by `Rules` in `config.json`, which are regexes on the ProPresenter name plus library path:
  - `item` maps to a PCO item title regex.
  - `afterHeader` maps to the first item under a PCO header. The sermon uses this, so its weekly title doesn't matter.
- **`IgnorePresentations`:** presentations that are never matched (Blank, Logo, Countdown).
- **Nothing matches:** Live stays where it is.

## Safety behaviour

- **Not armed outside service windows:** see `ArmMinutesBeforeService` and `ArmMinutesAfterServiceEnd`.
- **Items added mid-service:** an item turned off for the running service time (an invitation song added during the 9:30) gets turned on for that time, then followed. Set `IncludeExcludedItems: false` to disable this.
- **Skipped items:** if Live skips an item anyway, the bridge steps back once and stops chasing it.
- **No rewind:** once Live is on the last item of a service, it is never pulled backwards (post-service loops).
- **Control:** takes control of Live if someone else has it (`TakeControlIfNeeded`).

## Setup

1. **ProPresenter (FOH):** Settings > Network > Enable Network. Note the IP and port.
2. **Planning Center:** create a Personal Access Token at <https://api.planningcenteronline.com/oauth/applications>.
3. **Config:** copy `config.example.json` to `config.json` and fill in:
   - `PcoAppId` / `PcoSecret`
   - `ProPresenterHost` / `ProPresenterPort`
   - `ServiceTypeId`

   `config.json` is git-ignored. Never commit it.
4. **Test:**
   ```powershell
   .\Start-Bridge.bat -TestPP      # can we see ProPresenter?
   .\Start-Bridge.bat -ListPlan    # can we read the plan and PCO Live?
   .\Start-Bridge.bat -DryRun      # log what it would do, never touch Live
   ```
5. **Auto-start every Sunday:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-SundayTask.ps1
   ```

## Switches

| Switch | Effect |
|---|---|
| `-DryRun` | Log only; never moves Live (works outside service windows too) |
| `-IgnoreSchedule` | Armed all the time (for weekday testing with Live moving) |
| `-PlanId <id>` | Use a specific plan instead of today's |
| `-TestPP` / `-ListPlan` | Connectivity checks |

## Files

| File | Purpose |
|---|---|
| `PcoLiveBridge.ps1` | The bridge |
| `Start-Bridge.bat` | Double-click launcher |
| `Install-SundayTask.ps1` | Registers the weekly Task Scheduler job |
| `config.example.json` | Template config (copy to `config.json`) |
| `logs/` | Daily logs (git-ignored) |

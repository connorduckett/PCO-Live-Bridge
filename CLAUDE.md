# PCO Live Bridge: notes for Claude Code

Drives **Planning Center Services Live** from **ProPresenter**: polls the ProPresenter network API for the active presentation, matches it to an item in today's PCO plan, and steps Live forward/back to it. Read `README.md` for user-facing behaviour; this file covers internals, decisions and gotchas.

## Files

| File | Purpose |
|---|---|
| `PcoLiveBridge.ps1` | The whole bridge (single script). Must run on **Windows PowerShell 5.1** and **PowerShell 7** (Mac/Linux) |
| `config.example.json` | Template. Real configs (`config.json`, `config-*.json`) hold secrets and are git-ignored. **Never commit them** |
| `Start-Bridge*.bat` / `Start-Bridge*.command` | Windows / Mac launchers (`-ConfigPath` picks the config) |
| `Install-SundayTask.ps1` / `Install-SundayTask-Mac.sh` | Weekly auto-start (Task Scheduler / launchd) with `-OnlyIfServiceToday`. Options for days (`-Days` / `--days`) and a per-config task (`-ConfigPath` / `--config`); `config.json` keeps the original task name "PCO Live Bridge" / label `org.pcolivebridge.sunday` |
| `logs/` | Daily logs `pco-live-bridge_YYYY-MM-DD.log` (git-ignored). The source of truth for what happened on a Sunday |

## Coding rules

- **PS 5.1 compatible:** no `??`, no `?.`, no ternary, no `-AsHashtable`, no `-SkipHttpErrorCheck`. `$PSScriptRoot` is empty in param defaults on 5.1; use `$ScriptDir`.
- **Keep `PcoLiveBridge.ps1` pure ASCII with CRLF.** 5.1 misreads BOM-less UTF-8 (use `’` in regexes, not curly quotes).
- `.command` / `.sh` must stay LF (enforced in `.gitattributes`).
- Parse-check after edits:
  `[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$e)`

## External APIs (verified against real systems)

**ProPresenter 7.9+ (21.x):**

- `GET /version`
- `GET /v1/presentation/active` → `presentation.id.{uuid,name}`, `presentation_path` (includes the library folder, which rules can match on)
- `GET /v1/playlist/active` → `presentation.item.name`

**Planning Center Services v2** (Basic auth with a Personal Access Token):

- `GET .../plans/{id}/live?include=current_item_time,controller`
  - Live id == plan id.
  - The current ItemTime has `relationships.item` and `relationships.plan_time`.
  - **Use `data.links.self` for actions.**
- **Actions:** `POST .../plans/{id}/live/go_to_next_item`, `go_to_previous_item` and `toggle_control`. The path ends at `/live/`; **no live id**, or you get a 404.
- **Live skips headers and any item whose ItemTime is `exclude: true` for that plan time.** Items added during a service are usually excluded for the running time.
- **`PATCH item_times/{id}` with `length` → 422 "length cannot be assigned".** Recorded Live times cannot be fixed via API. Whether `exclude` is assignable is **not yet confirmed**; the code tries and falls back.
- Only next/previous exist (no "go to item"), so the bridge steps and re-reads Live after each step.
- `toggle_control` toggles: only call it when the controller != `/services/v2/me`.
- **Passing an item in Live re-records its time.** Rewinding then stepping forward destroys real times. That is why the bridge avoids rewinds.

## Behaviour and why

- **Arming:** active only from `ArmMinutesBeforeService` (5) before each *service*-type plan time until `ArmMinutesAfterServiceEnd` (30) after it. Rehearsal and other times are ignored. (An always-armed copy once timed a rehearsal into the 9:30.)
- **Single instance:** a named mutex `Local\PcoLiveBridge` (skipped for DryRun/TestPP/ListPlan). Two copies fighting over Live made items look "skipped" and corrupted times (Nov 1).
- **Target choice:** among matching items, the nearest at/after the current position, otherwise the nearest behind.
- **Second service handoff:** an earlier item fires, the current service's scheduled end has passed, and the next service starts within `SecondServiceLeadMinutes`, so the target goes into the next plan time.
- **No long rewinds:** never move back more than `MaxBackItems` (2) within a service. A song reused as the invitation would otherwise drag Live back.
- **Finished service:** if Live is on the last item, never rewind. A post-service loop once re-timed the whole 11:00. A held presentation is re-checked every 30 s so the next service's handoff window can open without a restart.
- **Overshoot detection:** if the step direction flips, the target is unreachable (excluded). Step back once and remember it in `$Script:Skipped`.
- **Excluded items:** `Ensure-ItemIncluded` tries to PATCH `exclude:false` for that plan time before moving.
- **No match:** reload the plan immediately (items get added mid-service), then give up, and Live stays put.
- **Config is read only at startup:** changing rules requires a restart. Startup validates it (numeric `ServiceTypeId`, no `PASTE_` placeholders, every rule has `match` + `item`/`afterHeader`, all regexes compile) so other churches get a clear error instead of a mid-service failure. `ArmMinutesBeforeService` defaults to 5 if missing (was -1/always armed).
- **The repo is public-facing:** keep README, `config.example.json` and launchers generic. Church-specific names, IPs and history go in `CLAUDE.local.md` only.

## Testing

- **On the real setup:**
  - `-TestPP` checks ProPresenter.
  - `-ListPlan` reads the plan and Live and saves `logs/live-debug.json`.
  - `-DryRun` logs only.
  - `-IgnoreSchedule` arms outside service windows.
  - `-ListServiceTypes` lists service types.
- **During a service, only change `config*.json` / the script if necessary.** A restart is safe: on start it re-evaluates what's on screen and logs "already on" if Live is right.
- **Mock testing without real systems:** write a small local HTTP server that mimics the endpoints above (ProPresenter + PCO with `PcoBaseUrl` pointed at it, a Live position list per service plan time, exclude sets, PATCH). This is how every behaviour above was regression-tested.

## Open items

- `exclude` PATCH: unverified against real PCO.
- `-ListServiceTypes` and the Mac launchers/launchd installer: tested on a mock / Linux pwsh only, not on real PCO / a real Mac. The Mac installer's `--days`/`--config` plist output was checked with a stubbed `launchctl`.
- `Install-SundayTask.ps1` `-Days` / `-ConfigPath` / `-Uninstall`: parse-checked, not yet registered on a real PC.
- Ideas not built yet: a `Setup` wizard that writes `config.json`; press the final "Next" automatically after the last service's last item to end Live; a per-service timing summary written from the log.

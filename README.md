# PCO Live Bridge

**Run Planning Center Services Live automatically from ProPresenter.**
Nobody has to sit and click "Next" in Live. The bridge watches which presentation your FOH ProPresenter is showing and moves Planning Center Live to the matching item in the plan.

- **Windows:** PowerShell 5.1 (built in) or 7. Nothing to install.
- **Mac:** PowerShell 7 (free, one install). See [Mac setup](#mac-setup).
- ProPresenter 7.9 or newer (uses its network API).
- A Planning Center account that can control Services Live for the service type.
- The computer running the bridge must reach ProPresenter over the network. It can be the ProPresenter computer itself.

> **Try it on a weekday first.** The bridge moves a real Services Live session, and Live records item times as it goes. Do a dry run and a rehearsal before trusting it on a Sunday (see [Test](#4-test)).

## How it works

1. Every half-second the bridge asks ProPresenter which presentation is live.
2. When the operator fires a **new** presentation (held for 2 s), it finds the matching item in **today's plan**:
   - **Songs** match by name. Case, punctuation, `(Live)`, `[G]` and leading `03 -` are ignored.
   - **Everything else** (welcome, announcements, scripture, sermon…) matches through `Rules` in `config.json`.
3. It steps PCO Live forward or back until Live is on that item.
4. **No match** (videos, one-offs, Blank/Logo): Live stays where it is.

### A typical Sunday

| When | What the bridge does |
|---|---|
| Early morning (scheduled start) | Starts, loads today's plan, waits. Rehearsal clicks don't touch Live |
| 5 min before each service time in the plan | Arms and moves Live to whatever is on screen |
| During the service | Follows ProPresenter |
| Between services | When the next service's opener fires after the first service's scheduled end, Live moves into the next service time |
| 30 min after the last service ends | Exits |

### Safety behaviour

- **Not armed outside service windows**, so rehearsals and run-throughs are ignored.
- **One copy only:** a second copy (double-click plus scheduled task) exits on its own.
- **No rewinds:**
  - Live is never dragged back more than `MaxBackItems` (2) items. A song reused later in the service won't pull Live back to its earlier slot. Add it again later in the plan instead.
  - Once Live reaches the last item of a service, a post-service loop won't pull it back to the top.
- **Items added during the service:** if an item (e.g. an invitation song) is turned off for the running service time, the bridge turns it on for that time and follows it (`IncludeExcludedItems`). If PCO refuses, Live stays put.
- **Items Live won't land on:** the bridge steps back once and stops chasing them.
- **Last-minute plan edits:** unmatched presentations trigger an immediate plan reload, so items added a minute ago are found.

## Setup (about 15 minutes)

### 0. Download

On GitHub, click **Code → Download ZIP**, unzip it somewhere permanent (e.g. `Documents\PCO-Live-Bridge`), and run everything from that folder. Or `git clone` it so you can `git pull` updates later. Updates never overwrite your `config*.json` files or `logs/`.

### 1. ProPresenter

On the ProPresenter computer that runs the service: **Settings → Network → Enable Network**. Note the IP address and port. If the bridge runs on that same computer, use `127.0.0.1`.

### 2. Planning Center token

Sign in at <https://api.planningcenteronline.com/oauth/applications> → **Personal Access Tokens → New**. Copy the **Application ID** and **Secret**.

The bridge acts as you in Live, so your account needs rights to control Live for that service type. Keep the secret private.

### 3. Config

1. Copy `config.example.json` to **`config.json`**. `config.json` is git-ignored; never commit it.
2. Fill in:
   - `ProPresenterHost` / `ProPresenterPort`
   - `PcoAppId` / `PcoSecret`
3. Find your service type ID and put it in `ServiceTypeId`:
   ```powershell
   .\Start-Bridge.bat -ListServiceTypes
   ```
4. Adjust `Rules` for how your team names presentations (see [Matching rules](#matching-rules)). The example rules cover common names: welcome, announcements, scripture, sermon, offering, communion. Every setting is described in [Config reference](#config-reference).

The bridge checks the config when it starts and says exactly what's wrong (missing token, non-numeric service type, a broken regex in a rule).

### 4. Test

```powershell
.\Start-Bridge.bat -TestPP      # can it see ProPresenter? fire a slide first
.\Start-Bridge.bat -ListPlan    # can it read today's/next plan and PCO Live?
.\Start-Bridge.bat -DryRun      # click through your playlist: logs what it WOULD do, never touches Live
```

In the dry run, any presentation that logs `no plan match` needs a rule (see below), unless you want Live to ignore it.

### 5. Auto-start every Sunday

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-SundayTask.ps1
```

This starts the bridge on Sundays at 7:00, 8:30, 9:15 and 10:45, and whenever you sign in. Whichever comes first wins. The bridge exits on days with no plan, so extra start times are harmless. Pick times before (or during) your services:

```powershell
.\Install-SundayTask.ps1 -At '6:30 AM','8:00 AM'                     # your own times
.\Install-SundayTask.ps1 -At '4:00 PM','7:00 AM' -Days Saturday,Sunday
.\Install-SundayTask.ps1 -ConfigPath .\config-pm.json -At '3:00 PM'  # a second service type gets its own task
.\Install-SundayTask.ps1 -Uninstall                                  # remove (add -ConfigPath for the others)
```

The task runs only while you're signed in on that PC. Only one copy of the bridge runs at a time, so give each config start times that don't overlap another config's services.

## Mac setup

The bridge is the same script on Mac; only the launchers and auto-start differ.

1. **Install PowerShell 7** with Homebrew:
   ```bash
   brew install --cask powershell
   ```
   Or use the installer from <https://aka.ms/powershell-release?tag=stable>.
2. **Allow the launchers to run.** Files downloaded from GitHub lose their "executable" flag. In Terminal, in the bridge folder, run this once:
   ```bash
   chmod +x *.command *.sh
   ```
   The first time you double-click `Start-Bridge.command`, macOS may say it's from an unidentified developer. Right-click it, choose **Open**, then **Open** again.
3. **Config:** steps 1–3 of [Setup](#setup-about-15-minutes) are the same. Commands look like this:
   ```bash
   ./Start-Bridge.command -ListServiceTypes
   ./Start-Bridge.command -TestPP
   ./Start-Bridge.command -ListPlan
   ./Start-Bridge.command -DryRun
   ```
   Or double-click **Start-Bridge.command** to run it live.
4. **Auto-start every Sunday:**
   ```bash
   bash Install-SundayTask-Mac.sh                          # Sundays 7:00, 8:30, 9:15, 10:45 + at login
   bash Install-SundayTask-Mac.sh 6:30 8:00                # your own times (24-hour)
   bash Install-SundayTask-Mac.sh --days Sat,Sun 16:00 7:00
   bash Install-SundayTask-Mac.sh --config config-pm.json 15:00
   bash Install-SundayTask-Mac.sh --uninstall              # remove (add --config for the others)
   ```
   The auto-started bridge runs in the background with no window. Check `logs/` to see what it did. The Mac must be on and you must be logged in. If it was asleep at a start time, macOS runs it on wake.

`Start-Bridge-PM.command` and `Start-Bridge-Special.command` work like their `.bat` twins.

## Matching rules

`Rules` are checked in order, first match wins. Each rule is a regex (`match`) tested against the ProPresenter **presentation name plus its library path**, and points to either:

- `item`: a regex on the **PCO item title**, or
- `afterHeader`: the first item under a **PCO header**. Use this for the sermon, whose title changes weekly.

If several plan items match (e.g. two "Scripture" items), Live goes to the **next one ahead** in the order.

Patterns are .NET regular expressions. `(?i)` makes them case-insensitive and `^` means "starts with". In JSON a backslash is written twice (`\\d` for `\d`). A rule's `match` can be loose, but its `item` should only hit the one plan item you mean.

Example: send anything from a "Sermon Notes" library, or named like `11-8-26 …`, to the item under the "THE WORD" header:

```json
{ "match": "(?i)sermon notes|^\\s*\\d{1,2}-\\d{1,2}-\\d{2,4}\\b", "afterHeader": "(?i)^the word" }
```

### Tips for your ProPresenter team

- **Songs:** name the presentation with the song's title as it appears in Planning Center. Songs need nothing else.
- **Everything else:** use a consistent word in the name (`Welcome`, `Announcements`, `Scripture`, `Sermon`) so one rule covers every week. A service-time suffix like `Welcome 11am` is fine.
- **Sermons:** keep them in their own library (e.g. "Sermon Notes") and point a rule at the item under the sermon header with `afterHeader`.
- **Things not in the plan** (walk-in videos, specials, countdowns) need nothing: Live stays put. Add them to `IgnorePresentations` if they could accidentally match a song name.
- Clicking through the playlist during a dry run (`-DryRun`) shows which presentations match and which don't.

## Config reference

Only the first five settings are required. The rest have sensible defaults and can be left out.

| Setting | Default | Meaning |
|---|---|---|
| `ProPresenterHost` / `ProPresenterPort` | `127.0.0.1` / `1025` | ProPresenter network address (Settings → Network) |
| `PcoAppId` / `PcoSecret` | | Planning Center Personal Access Token |
| `ServiceTypeId` | | Which service type's plans to follow (`-ListServiceTypes`) |
| `Rules` | none | Presentation → plan item rules, see above |
| `IgnorePresentations` | none | Regexes for presentations to always ignore (blank, logo, countdown…) |
| `ArmMinutesBeforeService` | `5` | Start following this many minutes before each service time. `-1` = always armed (not recommended) |
| `ArmMinutesAfterServiceEnd` | `30` | Stop following this long after a service's scheduled end |
| `SecondServiceLeadMinutes` | `20` | How close the next service must be before its opener moves Live into it |
| `MaxBackItems` | `2` | Never move Live back more than this many items |
| `IncludeExcludedItems` | `true` | Turn on an item that's turned off for the running service time, so Live can land on it |
| `TakeControlIfNeeded` | `true` | Take control of Live if someone else has it |
| `DebounceSeconds` | `2` | A presentation must stay up this long before Live moves (skips quick click-throughs) |
| `MatchThreshold` | `60` | How close (0–100) a presentation name must be to a song title to count |
| `PollIntervalMs` | `500` | How often ProPresenter is checked |
| `MaxStepsPerMove` | `30` | Safety cap on steps for one move |
| `PlanRefreshMinutes` | `5` | How often the plan is re-read for changes |
| `LogDirectory` | `logs` | Where daily logs go |
| `DisarmedUntil` | none | A date/time (e.g. `2026-12-01 08:00`). The bridge won't move Live before it |

The config is read when the bridge starts, so restart it after changes.

## Other service types (evening services, special events)

Make a second config (e.g. `config-pm.json` with a different `ServiceTypeId` and rules) and launch it with:

```powershell
.\Start-Bridge.bat -ConfigPath .\config-pm.json
```

`Start-Bridge-PM.bat` / `.command` and `Start-Bridge-Special.bat` / `.command` are ready-made launchers for `config-pm.json` and `config-special.json`. Copy and rename them for any other config. `config-*.json` files are git-ignored.

## Switches

| Switch | Effect |
|---|---|
| `-DryRun` | Log only; never moves Live (works outside service windows too) |
| `-IgnoreSchedule` | Armed all the time (for weekday testing with Live moving) |
| `-PlanId <id>` | Use a specific plan instead of today's |
| `-ConfigPath <file>` | Use another config file |
| `-TestPP` / `-ListPlan` / `-ListServiceTypes` | Setup checks |

## Troubleshooting

Everything the bridge does is written to `logs/pco-live-bridge_<date>.log`. Start there.

| Log says | Likely cause |
|---|---|
| `No response from ProPresenter` / `Lost ProPresenter` | Network not enabled in ProPresenter, wrong IP or port, or a firewall between the computers |
| `PCO ... failed (401)` | Wrong `PcoAppId` / `PcoSecret`, or the token was revoked |
| `PCO ... failed (403)` | Your Planning Center account can't control Live for that service type |
| `No service in this plan today` | No plan dated today in that service type |
| `no plan match, PCO Live stays put` | The name doesn't match a song title or any rule. Add a rule, or leave it if Live should stay put |
| `not armed yet` | It arms `ArmMinutesBeforeService` before each **service** time; rehearsal times are ignored. Use `-IgnoreSchedule` to test outside service times |
| `Another PCO Live Bridge is already running` | A second copy started (scheduled task plus a double-click). The first copy keeps going; this is expected |
| Windows: "running scripts is disabled" | Use the `.bat` launchers, which bypass the execution policy for this script only |

## Things to know

- **Recorded times can't be edited through the API.** If Live gets moved wrong mid-service, the item times in Planning Center stay wrong. The daily log in `logs\` has the real timeline.
- **Ending Live:** after the last item, press **Next** once in Services Live to end it. Don't step back through the order first; Live re-times everything you pass.
- **The bridge takes control of Live** if someone else has it. Set `TakeControlIfNeeded` to `false` to stop that.

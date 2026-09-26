# MATLAB safety engine

The "engineering brain" of the chemical-process safety digital twin (BuildOdoo 2026, team T05).
It reads live readings and safety limits from Odoo, decides **SAFE / AT_RISK / CRITICAL** for each of the
five monitored locations, and posts the verdict back. CoppeliaSim, the ROS bridge and Odoo are Riya's side
(see the repo root README); everything here is plain MATLAB functions, one folder, no toolboxes.

```
CoppeliaSim -> bridge -> Odoo  <--HTTP--  MATLAB (this folder)
                          ^                  |  GET  /api/live_readings/<location>   raw F / PSI / gpm
                          |                  |  GET  /api/equipment/<location>       limits + pipe spec
                          +------------------+  POST /api/safety_status/<location>   safe|warning|critical + reason
                                                POST /api/engineering_results/<location>  (optional, format assumed)
```

Locations: `feed_pipeline`, `column_bottom`, `column_top`, `bottoms_output`, `distillate_output`.

## Quick start
```matlab
cd matlab                      % this folder
run_all_tests                  % every test that needs no server (about 11 files)
dashboard_demo                 % window with SIMULATED readings, no Odoo needed
live_dashboard                 % the real thing against Odoo, READ-ONLY
live_dashboard(struct('send_http', true))     % also POST verdicts (a CRITICAL latches in Odoo!)
```
Point it at Odoo by editing `config.json` (both URLs) or `setenv('ODOO_BASE_URL','http://<ip>:8069')`. The IP changes
with the Wi-Fi, so re-check with `ipconfig getifaddr en0`. `DEMO_CHECKLIST.md` is the one-page runbook.

## How a decision is made
Per location, every cycle (default 1.0 s): fetch raw reading -> `adapt_reading` (F to C, PSI to bar, gpm to kg/s,
timestamp) -> three checks -> `combine_checks` (worst status wins) -> map to Odoo's names -> POST.

| Status | Rule (pressure, temperature, flow alike) | Action |
|---|---|---|
| SAFE | below 90 % of the limit | CONTINUE |
| AT_RISK (Odoo `warning`) | at or above 90 % of the limit, **or** a rising rate over its threshold | ADJUST_VALVE (informational: valve 50 %) |
| CRITICAL | at or above the limit (`>=`), or NaN / invalid data (fail safe) | SHUTDOWN (valve 0) |

- The temperature margin is 90 % of the limit **in deg C**, compared in Kelvin.
- A fast rise alone gives AT_RISK only; it never gives CRITICAL and never downgrades one.
- No usable data (fetch failures, or a timestamp frozen for 5 polls) is skipped for up to 3 polls, then fails safe to CRITICAL.
- Only SHUTDOWN moves a valve. Odoo latches a CRITICAL until Manual Reset.
- Internally SI (K, Pa, kg/s, m); conversion happens once, on the way in.

## Files
| Group | Files |
|---|---|
| Safety checks | `check_pressure`, `check_temperature`, `check_flow` (also velocity, Reynolds number, friction factor, pressure drop), `safety_defaults` (all tunables) |
| Glue | `adapt_reading`, `combine_checks`, `to_odoo_status`, `to_odoo_payload`, `to_engineering_payload` |
| Odoo I/O and config | `config.json`, `load_config`, `odoo_url`, `fetch_live_reading`, `parse_live_reading`, `load_limits_from_odoo`, `limits_from_equipment`, `diff_limits` |
| The loop | `default_settings`, `poll_cycle`, `run_safety_loop`, `run_safety_loop_live` |
| Dashboard | `live_dashboard`, `attach_dashboard`, `dashboard_create`, `dashboard_update` (pure data), `dashboard_render`, `dashboard_demo`, `at_risk_bands` |
| Tests | `test_*.m`, `run_all_tests` |

Style: pure functions (structured in, structured out, no prompts, no I/O in the logic), `&` / `|` instead of `&&` / `||`,
comments explain why. Status names are char vectors compared with `strcmp`, for older MATLAB versions.

## Tunables (`safety_defaults.m`, all placeholders unless noted)
margin `0.9`; AT_RISK valve `50`; pressure rate limit `20000` Pa/s and temperature `3` K/s (set above the scene's sensor
noise, **not** real plant physics); flow rate limit `2` kg/s^2; pipe roughness `4.5e-5` m. Loop settings
(`default_settings.m`): poll `1` s, `max_fetch_failures` 3, `max_stale_polls` 5, limits re-read from Odoo every `30` s
(a failed reload keeps the old limits). Limits and pipe geometry come from Odoo; water is hardcoded
(1000 kg/m3, 0.001 Pa.s).

## Testing
`run_all_tests` runs every test with fake data and no network. `run_all_tests('withMock')` adds `test_against_mock`,
which drives the real HTTP sender against a local stand-in for Odoo (`mock_odoo.py`, kept outside this repo; see the
header of `test_against_mock.m`). The dashboard's drawing code (`dashboard_create` / `dashboard_render`) needs a display and
is checked by eye with `dashboard_demo`.

## Known gaps and assumptions
- `/api/engineering_results` body format is **assumed**; `temperature_rate` and `pressure_rate` are not sent yet (units undecided).
- The first live POST to the real Odoo has not been made yet (only to the mock).
- `diameter` is used as given (inches to m), not reduced by wall thickness; it only affects the informational hydraulics.
- Reynolds number in the transitional range (2300 to 4000) uses the turbulent formula as an approximation.
- AT_RISK "adjust valve to 50 %" is text only; there is no partial-valve control.

## Repo etiquette
Only add new commits on top of `main`; never amend, rebase or force-push shared history. Avoid committing Wi-Fi-specific IP changes to `config.json`; edit it locally or use `ODOO_BASE_URL`.

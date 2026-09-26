# Demo checklist: MATLAB safety engine (one page)

**Roles:** Noel = MATLAB (engine + dashboard). Riya = CoppeliaSim, bridge, Odoo (holds the reset).
**Golden rule:** a CRITICAL **latches** in Odoo until Riya presses Manual Reset. Never fire a real spike until you mean to.

## 1. At the venue, before anything starts (10 min)
- [ ] Both laptops on the **same Wi-Fi**. Each runs `ipconfig getifaddr en0`; the first three numbers must match (e.g. `192.168.1.x`).
- [ ] Riya says her Odoo IP out loud. Edit **your** `config.json` (both URLs), or `setenv('ODOO_BASE_URL','http://<ip>:8069')`. Do not commit it.
- [ ] Both laptops **plugged in**, lid open, sleep off (`caffeinate -dims` in a terminal).
- [ ] Riya: Odoo up, CoppeliaSim scene playing, bridge running, all five pipes **safe/open**.
- [ ] Check the link (should print a struct with temperature_f, pressure_psi, flow_gpm, timestamp):
      `webread('http://<ip>:8069/api/live_readings/column_bottom')`
- [ ] Riya: temperature limits agreed so idle is SAFE (tuned values: feed 100, column_bottom ~190, column_top ~152, bottoms ~184, distillate ~156 °F).

## 2. Read-only run (5 min). Nothing is sent
```matlab
cd ~/matlab_safety_brain
live_dashboard()
```
- [ ] Banner is **blue: READ-ONLY**. Limits table printed in the command window.
- [ ] All five rows **green**, ages under ~2 s, charts moving. **Any amber/red at idle? Stop and fix limits first.**
- [ ] Riya fires `demo_spike` and **holds it at least 5 s**: rows go amber then red, charts cross the amber then red lines.

## 3. Going live (only after step 2 is clean AND Noel says go)
- [ ] Riya confirms she is at her Odoo screen with **Manual Reset** ready.
- [ ] Close the window. Restart with posting on:
      `live_dashboard(struct('send_http', true))`
- [ ] Banner turns **red: POSTING ON**. Riya sees `safe` arrive for each pipe (first POST is harmless).
- [ ] Optional: add `'send_engineering', true` **only if** Riya has pushed her `/api/engineering_results` endpoint.
- [ ] Riya fires the spike (hold 5+ s). Expect: MATLAB row goes red, Odoo shows CRITICAL + valve closed + Maintenance ticket + Discuss alert for that pipe.
- [ ] Riya presses **Manual Reset** on each latched pipe before the next run.

## 4. If something looks wrong
| Symptom | Likely cause | Do this |
|---|---|---|
| Window says "Could not load limits" | Wrong IP / Odoo down / different Wi-Fi | Re-check step 1; the loop refuses to start on purpose |
| Rows show **NO DATA** / status CRITICAL "No usable sensor data" | Bridge stopped or reading frozen (3 polls) | Riya restarts the bridge. This fail-safe is intended |
| Row stuck **amber at idle** | Limit too close to idle | Riya raises the limit; MATLAB re-reads limits every 30 s, no restart |
| `[NOT SENT: ...latched CRITICAL...]` | Odoo is latched | Riya presses Manual Reset |
| Window frozen / MATLAB busy | Network stall (each fetch waits up to 5 s) | Wait 30 s; if it persists, close the window and restart |
| Banner says LAST n RELOAD(S) FAILED | Limits endpoint unreachable | Loop keeps the old limits; fix the network |

## 5. Facts to say out loud if asked
- Poll **every 1.0 s**; the bridge posts every 1.0 s; worst-case delay from scene to MATLAB is about **2 s**.
- Status is decided by **three checks** (pressure, temperature, flow): SAFE below 90 % of the limit, AT_RISK from 90 % (Odoo `warning`), CRITICAL at or above the limit. **Worst one wins.**
- A fast rise alone gives AT_RISK, never CRITICAL. Bad or missing data goes **CRITICAL (fail safe)**.
- Only **SHUTDOWN** moves a valve. AT_RISK "adjust valve to 50%" is informational (no partial valve exists).
- Reynolds number, friction factor, velocity, pressure drop are computed every cycle (water, 1000 kg/m3, 0.001 Pa.s).

## 6. Practice without the venue network (anytime, one Mac)
```
python3 ~/matlab_mock_odoo/mock_odoo.py --tuned        # terminal
```
```matlab
setenv('ODOO_BASE_URL','http://127.0.0.1:8069'); live_dashboard(struct('send_http', true))
```
Spike: `curl 'http://127.0.0.1:8069/mock/spike?hold=10'`. Reset: `curl http://127.0.0.1:8069/mock/reset/all`.
Full automatic check: start the mock, then `test_against_mock` in MATLAB.

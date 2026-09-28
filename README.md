# Predictive Safety and Monitoring System

**BuildOdoo 2026 (Heriot-Watt Tech Club × Odoo)** — Track 2: AI for Good, aligned with the UAE National Strategy for Artificial Intelligence 2031.

## The problem
In high-risk process plants, pressure and temperature excursions lead to equipment failures, environmental harm and injuries. ERP systems usually react afterwards: they log the damage and raise a repair ticket once the failure has already happened.

## What this system does
A digital twin of a distillation column streams live temperature, pressure and flow for five monitored pipes. A MATLAB safety engine checks every pipe once a second against that pipe's design limits in Odoo:
- **AT_RISK** (Odoo `warning`) at 90 % of a limit, or when pressure or temperature is rising faster than its rate threshold.
- **CRITICAL** at the limit.

A CRITICAL verdict closes **that pipe's** valve in the simulation, latches the pipe in Odoo until an operator presses Manual Reset, and opens a Maintenance request plus a Discuss alert that include MATLAB's reason.

## Architecture

```
 CoppeliaSim scene                ros_bridge.py                     Odoo 19                    MATLAB
 (emergency_valve.lua)            ROS 2 node in Docker              predictive_safety module   matlab/
 ─────────────────────            ─────────────────────             ────────────────────────   ──────────────────
 15 float signals  ──ZMQ API──►  polls all signals every 0.1 s
 (temp / pressure /               one HTTP thread per pipe:
  flow per pipe)                    POST /api/live_readings/<pipe> ──►  stores the reading  ──►  GET /api/live_readings/<pipe>
                                                                        and pressure history    GET /api/equipment/<pipe>
                                                                                                 checks limits + rates
                                                                        latches CRITICAL,  ◄──  POST /api/safety_status/<pipe>
                                                                        ticket + alert     ◄──  POST /api/engineering_results/<pipe>
 <pipe>_valve_shutdown  ◄──ZMQ──   GET /api/valve_commands/<pipe> ◄──  valve open / closed
 valve joint turns 90°
```

1. **CoppeliaSim**: the scene's Lua script writes `<pipe>_temperature` (°F), `<pipe>_pressure` (PSI) and `<pipe>_flow_rate` (gpm) for each pipe, and turns each pipe's valve according to `<pipe>_valve_shutdown`.
2. **ros_bridge.py** reads the signals over the CoppeliaSim ZMQ remote API. One thread per pipe posts that pipe's latest reading to Odoo every second and reads back that pipe's valve command.
3. **Odoo** stores each pipe's live values and pressure history. It holds the latched status and valve state.
4. **MATLAB** reads the live values and limits from Odoo, decides SAFE / AT_RISK / CRITICAL for each pipe, and posts the verdict (plus optional engineering results) back to Odoo.
5. Odoo turns a CRITICAL into `valve_command: closed`. The bridge picks it up within about a second and closes that valve in the scene.

## The 5 monitored locations
Each location is one Odoo record, named exactly as below. These names are the `<pipe>` part of every signal name and API path. The limits shown are the ones `scripts/seed_equipment.py` loads. All 5 share one pipe spec: carbon steel, API 5L X52, 6 in diameter, 0.28 in wall, 0.125 in corrosion allowance.

| Location | Valve in the scene | Design pressure | Design temperature | Flow limit | Length |
|---|---|---|---|---|---|
| `feed_pipeline` | `/Feed_Pipe/Feed_Valve` | 37 PSI | 105 °F | 0.18 kg/s | 25 m |
| `column_bottom` | `/Column_Bottom_Pipe/Column_Bottom_Valve` | 58 PSI | 190 °F | 0.20 kg/s | 5 m |
| `column_top` | `/Column_Top_Pipe/Column_Top_Valve` | 48 PSI | 152 °F | 0.19 kg/s | 8 m |
| `bottoms_output` | `/Bottoms_Pipe/Bottoms_Valve` | 57 PSI | 184 °F | 0.20 kg/s | 20 m |
| `distillate_output` | `/Distillate_Pipe/Distillate_Valve` | 50 PSI | 156 °F | 0.19 kg/s | 30 m |

## Simulation and the demo spike
`coppeliasim/reactor_simulation.ttt` is the scene. `coppeliasim/emergency_valve.lua` is a reference copy of its child script on `/Distillation_Column`; CoppeliaSim runs the copy embedded in the scene.

The scene also contains Feed_Tank, Condenser, Boiler and Output_Tank. They are visual only: no script reads or moves them.

All 5 pipes follow one shared "boil-up" level, as in a real column upset. Each pipe's readings are its own baseline plus that level times its own range, plus a little noise.

- **Idle:** the boil-up level stays between 0 and 0.10, moving by at most ±0.05 every 20 s. This keeps idle readings below every pipe's 90 % AT_RISK margin.
- **Demo spike:** publishing on the ROS topic `/demo_spike` sets the level to 1.0 and holds it for **30 s**. The level then decays at 0.05 per second, reaching the idle band again in about 18 s. At full level every pipe's pressure goes past its design pressure.
- **A shut valve relieves its pipe:** while a pipe's valve is closed, that pipe's readings ease back toward baseline (5 s time constant) instead of freezing at the spike level. As a result, a Manual Reset after the spike doesn't immediately trip again.
- **Spike refused while any valve is closed:** the bridge ignores `/demo_spike` and logs `DEMO SPIKE ignored: valve closed at …`. Manual Reset the closed pipes first.

Fire a spike from inside the ROS container:
```bash
ros2 topic pub --once /demo_spike std_msgs/msg/Empty '{}'
```

## The ROS bridge (`ros_bridge/ros_bridge.py`)
- A ROS 2 (Humble) node. It reads the scene through `coppeliasim_zmqremoteapi_client` at `host.docker.internal:23000`, and only the node's own thread talks to CoppeliaSim.
- Polls all 15 signals every 0.1 s.
- Runs one thread per pipe. Every second, each thread posts that pipe's reading (JSON-RPC) and reads back its valve command, so a slow request for one pipe never delays the others.
- Each HTTP call has a 1 s timeout and is retried once on a network error. A failure is logged once as `NOT WORKING`, then `RECOVERED` when it clears.
- If any pipe's values stop changing for more than 3 s (scene stopped, paused or unreachable), the bridge logs `NOT WORKING: no new reading in over 3s for …`.
- `ODOO_URL` defaults to `http://192.168.65.254:8069`, Docker Desktop's IPv4 address for the host.

## The Odoo module (`predictive_safety`)
Depends on `base`, `mail` and `maintenance`. The menu is **Predictive Safety → Pipelines**; the app itself is still listed in Odoo as "Predictive Safety System".

- **`predictive.safety.pipeline`**: one record per location. It holds:
  - the pipe spec and design limits;
  - fluid density and viscosity for MATLAB's hydraulics (defaults: water, 1000 kg/m³ and 0.001 Pa·s);
  - the live temperature, pressure, flow, valve position and last-updated time;
  - MATLAB's engineering results: velocity, Reynolds number, friction factor, pressure drop, temperature rate and pressure rate;
  - the latched `current_status` (safe / warning / critical) and `valve_state` (open / closed).
- **`predictive.safety.pressure.reading`**: pressure history. A reading is logged only when the pressure value changes.
- **Form view:**
  - Force Shutdown and Manual Reset buttons;
  - status and valve badges and the live values;
  - an Engineering Results section;
  - a Pressure History tab with a line chart of the last 50 readings against the design pressure.
- **Theme:** an industrial control-panel theme (`static/src/scss/predictive_safety.scss`), scoped to this module's own views.

### Latching, Force Shutdown and Manual Reset
- **Per pipe:** everything below applies to one pipe only; the other pipes are unaffected.
- **CRITICAL latches:**
  - When MATLAB posts CRITICAL for a pipe, Odoo sets it to `critical` / `closed`.
  - On the transition into CRITICAL only, Odoo creates one Maintenance request and posts one message in the **Plant Safety Alerts** Discuss channel (created if missing), both with MATLAB's reason.
  - Later SAFE/WARNING verdicts for that pipe are refused, with an error in the reply, until Manual Reset.
- **Force Shutdown** (form button): an operator closes the pipe by hand. It sets `critical` / `closed` and, if the pipe wasn't already critical, creates a "manual emergency shutdown" request and alert.
- **Manual Reset** (form button): clears the latch and sets `safe` / `open`. The bridge reopens the valve within about a second, and MATLAB's verdicts apply again.
- **WARNING** (MATLAB's AT_RISK) is shown on the record but leaves the valve open.
- **rosbridge must be running.** A MATLAB CRITICAL, Force Shutdown and Manual Reset each also publish a `std_msgs/Float32` on the ROS topic `/manual_override` through rosbridge at `ws://localhost:9090`: 2.0 for a MATLAB CRITICAL, 1.0 for Force Shutdown, −1.0 for reset. Nothing in this repo subscribes to that topic, since the valves move through `/api/valve_commands`. But if rosbridge can't be reached, Odoo raises an error and rolls the change back.

## API
`<pipe>` is always one of the 5 location names. Live values are raw scene units: °F, PSI and gpm. Timestamps are UTC ISO 8601. The routes use `auth='public'` with no authentication, so run the system only on a trusted network.

| Method | Path | Used by | Purpose |
|---|---|---|---|
| GET | `/api/equipment/<pipe>` | MATLAB | Spec and limits: `material`, `grade`, `diameter`, `thickness`, `corrosion_allowance`, `design_temperature`, `design_pressure`, `flow_limit` (kg/s), `pipe_length` (m), `fluid_density`, `fluid_viscosity` |
| GET | `/api/live_readings/<pipe>` | MATLAB | Latest reading for one pipe, plus its latched `status` and `valve_state` |
| GET | `/api/live_readings` | any client | The same for all 5 pipes, as a list |
| POST | `/api/live_readings/<pipe>` | ros_bridge.py | One pipe's reading (JSON-RPC) |
| GET | `/api/valve_commands/<pipe>` | ros_bridge.py | `{name, status, valve_command}`; `valve_command` is `open` or `closed` |
| POST | `/api/safety_status/<pipe>` | MATLAB | Safety verdict (JSON-RPC) |
| POST | `/api/engineering_results/<pipe>` | MATLAB | Computed results (plain JSON **or** JSON-RPC) |
| GET | `/api/live_pressure/<pipe>` | dashboards | `{name, pressure, status, valve_state, last_updated}` |

**Live reading** (GET response):
```json
{"location": "column_top", "temperature_f": 140.8, "pressure_psi": 43.2, "flow_gpm": 1.89,
 "timestamp": "2026-09-25T18:22:34.512+00:00", "status": "safe", "valve_state": "open"}
```
The bridge's POST carries `location`, `temperature_f`, `pressure_psi`, `flow_gpm`, `timestamp` and optionally `valve_position` (0 open, 1 closed).

**Safety verdict** (JSON-RPC). `status` is `safe`, `warning` or `critical`, in any case:
```json
{"jsonrpc": "2.0", "method": "call", "params": {"status": "critical", "reason": "Pressure 4.3 bar >= limit 4.0 bar"}}
```
- The reply is `result.ok` on success.
- Every error comes back as HTTP 200 with `result.error`: unknown pipe, invalid status, or a pipe latched CRITICAL that is refusing SAFE/WARNING.

**Engineering results.** Any of `velocity` (m/s), `reynolds_number`, `friction_factor`, `pressure_drop` (Pa), `temperature_rate` (K/s) and `pressure_rate` (Pa/s). A missing or `null` value keeps the previous one. Two body formats are accepted:
- **Plain JSON:** `{"velocity": 0.0078, "reynolds_number": 11890.2}`. The reply is `{"ok": true, "location": …, "updated": […]}`. Errors return HTTP 404 (unknown pipe) or 400 (not JSON, a value that isn't a number, no values).
- **JSON-RPC:** `{"jsonrpc": "2.0", "method": "call", "params": {…}}`. The same reply comes back inside `result`, with errors as HTTP 200 and `result.error`.

The GET endpoints return HTTP 404 with `{"error": …}` for an unknown pipe name.

## MATLAB safety engine (`matlab/`)
Noel's side, plain MATLAB functions with no toolboxes. `matlab/README.md` covers it in detail. In brief:
- **Once a second per pipe:** fetch the live reading and limits from Odoo, convert them to SI, then run the pressure, temperature and flow checks. The worst of the three checks sets the verdict.
- **Verdicts:**
  - AT_RISK at 90 % of a limit, or when pressure rises faster than 20000 Pa/s or temperature faster than 3 K/s;
  - CRITICAL at or above a limit, or when there's no usable data: 3 failed fetches in a row. Once a reading has stayed unchanged for 18 polls, each further poll counts as a failed fetch, so a frozen feed trips after about 20 s.
- **Posting is off by default:** `live_dashboard(struct('send_http', true))` sends verdicts, and adding `'send_engineering', true` also sends engineering results. Odoo's address comes from `matlab/config.json` or the `ODOO_BASE_URL` environment variable.
- **The dashboard also shows Odoo's own latch state.** A "Valve (Odoo)" column turns the whole row red whenever Odoo reports a pipe `critical` or `closed`, even if MATLAB's sensor verdict is SAFE (for example after a Force Shutdown).

## Running it
1. **Odoo 19:** clone this repo into a folder named `predictive_safety` on your `addons_path`, and install the app.
2. **Load the 5 pipe records:**
   ```bash
   ODOO_PASSWORD=... python scripts/seed_equipment.py
   ```
   It is safe to re-run: records are matched by name and updated. `ODOO_URL` (default `http://localhost:8069`), `ODOO_DB` and `ODOO_USERNAME` (both default `admin`) can be overridden.
3. **CoppeliaSim:** open `coppeliasim/reactor_simulation.ttt` and press Play. The ZMQ remote API must be on port 23000.
4. **ROS 2 container:** a ROS 2 Humble container with `rosbridge_server` and `coppeliasim_zmqremoteapi_client`, port 9090 published to the host. The joint test expects it to be named `ros_bridge_env`, with the bridge at `/root/ros_bridge.py` logging to `/root/ros_bridge.log`. Inside it, start:
   ```bash
   ros2 launch rosbridge_server rosbridge_websocket_launch.xml
   python3 /root/ros_bridge.py >> /root/ros_bridge.log 2>&1
   ```
5. **MATLAB:** set `odoo_base_url` in `matlab/config.json` to the Odoo machine's LAN address, then run `live_dashboard(struct('send_http', true))`.

`check_db.py` lists the databases on `http://localhost:8069`, which is useful for finding the database name.

### End-to-end joint test
Run it on the host (the machine running Docker), with everything above running and all 5 pipes SAFE:
```bash
ODOO_PASSWORD=... scripts/run_joint_test.sh
```
`scripts/run_joint_test.sh` copies `scripts/joint_test.py` into the `ros_bridge_env` container and runs it there.
1. **Pre-flight:** the watcher checks that the scene is playing, that all 5 pipes are SAFE with valves open, and that MATLAB is posting (its engineering results must change within 5 s). If any check fails it prints `NOT READY` and exits with code 2, without firing.
2. **Spike:** the runner fires `/demo_spike`. The watcher waits for `DEMO SPIKE triggered` in the bridge log and times everything from that log line.
3. **During the run:**
   - reports each valve as it closes, and every pipe's pressure as a percentage of design every 5 s;
   - at 55 s, presses Manual Reset on all 5 pipes;
   - keeps watching until 100 s for re-trips and new Maintenance requests.
4. **Result:** it prints `PASS` (exit code 0) only if all 5 closed, all 5 reopened on reset, none re-tripped, no new requests appeared, and all 5 end SAFE and open. Otherwise it prints `FAIL` (exit code 1).

`RESET_AT` and `WATCH_UNTIL` change the timing, for example `RESET_AT=60 WATCH_UNTIL=120`. `ODOO_URL`, `ODOO_DB` and `ODOO_USERNAME` are passed through to the watcher. Each run leaves 5 Maintenance requests and 5 Plant Safety Alerts messages behind.

## Repo structure
The repo root is the `predictive_safety` Odoo module itself.
```
├── __manifest__.py        # Odoo module manifest
├── models/                # predictive.safety.pipeline (one record per pipe) and the pressure history
├── views/                 # Pipelines list and form: status/valve badges, Force Shutdown / Manual Reset, pressure chart
├── controllers/           # The JSON API (see API)
├── security/              # Access rights
├── static/                # Control-panel theme, scoped to this module's views
├── coppeliasim/           # Scene (reactor_simulation.ttt) and a reference copy of its Lua script
├── ros_bridge/            # ros_bridge.py: CoppeliaSim <-> Odoo relay, one thread per pipe
├── matlab/                # MATLAB safety engine, dashboard and tests (see matlab/README.md)
├── scripts/               # seed_equipment.py, run_joint_test.sh + joint_test.py
└── check_db.py            # Lists the Odoo databases on localhost
```

## Team
- **Noel**: MATLAB safety engine and dashboard
- **Riya**: CoppeliaSim, ROS bridge, Odoo integration

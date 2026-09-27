[README.md](https://github.com/user-attachments/files/32563372/README.md)
# A-Z Predictive Safety System

**BuildOdoo 2026 (Heriot-Watt Tech Club × Odoo)** — Track 2: AI for Good, aligned with the UAE National Strategy for Artificial Intelligence 2031.

## The Problem
In high-risk sectors like oil and gas, unpredictable chemical reactions and pressure drops lead to catastrophic equipment failures, environmental hazards, and loss of life. Traditional ERP systems are purely reactive — they log equipment damage and issue repair tickets only *after* a disaster has already occurred.

## The Solution
An autonomous AI safety agent that bridges Operational Technology (OT) and Information Technology (IT). By continuously comparing live physical telemetry against equipment-specific engineering safety limits, the system predicts critical failures before they happen — automatically shutting down the plant while simultaneously triggering a company-wide crisis management workflow.

## Architecture

```
CoppeliaSim (OT)  →  ROS 2  →  MATLAB (Analytical Brain)  →  Odoo (Command Center)
   3D digital twin     bridge     SAFE / WARNING / CRITICAL      shutdown + workflows
```

| Layer | Role |
|---|---|
| **CoppeliaSim** | 3D digital twin of the process (Feed → Reactor → Flash Drum → Pipeline → ESD Valve). Publishes live telemetry, hosts the controllable emergency shutdown valve. |
| **ROS 2** | Communication layer routing telemetry between CoppeliaSim, MATLAB, and Odoo via `rosbridge_websocket` (port 9090). |
| **MATLAB** | Engineering/safety engine. Callable functions (e.g. `check_reactor`, `check_pipeline`) combine live telemetry with equipment specs to evaluate safety envelopes, returning SAFE / WARNING / CRITICAL. |
| **Odoo** | UI, Equipment Library, monitoring dashboard, and emergency management. On CRITICAL: halts production (Quality), opens a Maintenance ticket, dispatches Field Service, scraps/reorders materials (Inventory & Purchase), and notifies shift workers (Discuss). |

## Demo Scenarios
- **Primary:** Feed disturbance → reactor temp/pressure deviates → MATLAB flags CRITICAL → Odoo triggers ESD valve closure → maintenance record created.
- **Secondary:** Pipeline pressure spike → MATLAB detects envelope breach → CRITICAL → ESD valve closes → emergency/maintenance response.

## Repo Structure
The repo root is the `predictive_safety` Odoo module itself (clone it into a folder named `predictive_safety` on your Odoo `addons_path`):
```
├── __manifest__.py       # Odoo module manifest
├── models/               # One equipment record per monitored pipe: live readings, pressure history,
│                         #   latching status, Force Shutdown / Manual Reset, Discuss alerts
├── views/                # Pipeline form (status badges, pressure chart) and list view
├── security/             # Access rights
├── controllers/          # JSON API used by ros_bridge.py and MATLAB (see API below)
├── static/               # Industrial control panel theme, scoped to this module's views
├── ros_bridge/           # CoppeliaSim <-> Odoo relay: posts all 5 pipes' readings, applies each
│                         #   pipe's valve command (runs in the ROS 2 Docker container)
├── coppeliasim/          # 3D scene + Lua script (the /Distillation_Column child script)
├── check_db.py           # Helper: lists Odoo databases
├── scripts/              # seed_equipment.py: creates/updates the 5 pipe records and their limits
│                         #   run_joint_test.sh: one end-to-end safety-loop test, PASS/FAIL
├── matlab/               # check_pressure.m: SAFE / AT_RISK / CRITICAL pressure check, with test_check_pressure.m
└── docs/                 # (planned) Architecture diagrams, notes
```

`ros_bridge.py` reads `ODOO_URL` from the environment (default `http://192.168.65.254:8069`, Docker Desktop's IPv4 address for the host).
`scripts/seed_equipment.py` loads the 5 pipe records with their limits: `ODOO_PASSWORD=... python scripts/seed_equipment.py`.
`scripts/run_joint_test.sh` runs one full safety-loop test: it fires the demo spike, checks all 5 valves close, does a Manual Reset at 55 s and watches for re-trips until 100 s: `ODOO_PASSWORD=... scripts/run_joint_test.sh`. Needs Odoo, the playing scene, the bridge container and the MATLAB loop running, with all 5 pipes SAFE.

## API
Each of the 5 monitored pipes is its own Odoo equipment record, named exactly:
`feed_pipeline`, `column_bottom`, `column_top`, `bottoms_output`, `distillate_output`.
`<name>` below is always one of these. All values are raw scene units: °F, PSI, gpm; timestamps are UTC ISO 8601.

| Method | Path | Used by | Purpose |
|---|---|---|---|
| GET | `/api/equipment/<name>` | MATLAB | Pipe spec and limits: `material`, `grade`, `diameter`, `thickness`, `corrosion_allowance`, `design_pressure`, `design_temperature`, `flow_limit` (kg/s), `pipe_length` (m) |
| GET | `/api/live_readings` | MATLAB | Latest reading for all 5 pipes, as a list |
| GET | `/api/live_readings/<name>` | MATLAB | Latest reading for one pipe |
| POST | `/api/safety_status/<name>` | MATLAB | Safety verdict for one pipe (JSON-RPC, see below) |
| POST | `/api/live_readings/<name>` | ros_bridge.py | One pipe's live reading (JSON-RPC) |
| GET | `/api/valve_commands/<name>` | ros_bridge.py | That pipe's latched status and valve command |
| GET | `/api/live_pressure/<name>` | dashboards | Latest pressure, status and valve state for one pipe |

**Live reading** (GET response, and the POST payload from the bridge):
```json
{"location": "column_top", "temperature_f": 140.8, "pressure_psi": 43.2, "flow_gpm": 1.89,
 "timestamp": "2026-09-25T18:22:34.512+00:00", "status": "safe", "valve_state": "open"}
```
The bridge's POST carries `location`, `temperature_f`, `pressure_psi`, `flow_gpm`, `timestamp` and optionally `valve_position` (0 open, 1 closed); `status`/`valve_state` are only in GET responses.

**Safety verdict** - JSON-RPC body, `status` is `SAFE`, `WARNING` or `CRITICAL` (any case):
```json
{"jsonrpc": "2.0", "method": "call", "params": {"status": "CRITICAL", "reason": "Hoop stress exceeds 90% SMYS"}}
```
- A `CRITICAL` closes **only that pipe's** valve and creates one Maintenance ticket and one "Plant Safety Alerts" Discuss message with the reason.
- `CRITICAL` latches: later `SAFE`/`WARNING` for that pipe are refused until **Manual Reset** on that pipe's card in Odoo. Other pipes are unaffected.
- JSON-RPC errors come back as HTTP 200 with `result.error` (unknown pipe, invalid status, pipe latched), so check the result - e.g. in MATLAB:
  `if isfield(resp.result, 'error'), error(resp.result.error); end`
- The GET endpoints return HTTP 404 for an unknown `<name>`, so `webread` throws.

**Changed from the single-pipe version:** the old `P-101` record and the `location` parameter are gone - use the pipe name in the path instead (`/api/safety_status/column_top`, not `/api/safety_status/P-101` + `location`). `flow_limit`/`pipe_length` are now top-level fields of `/api/equipment/<name>` (no `locations` list).

## Team
- **Noel** — MATLAB safety-envelope engineering logic
- **Riya** — CoppeliaSim, ROS bridge, Odoo integration

## Status
🚧 Work in progress — see commit history for current integration state.

"""Watch one full safety-loop run: demo spike -> all 5 valves close ->
hold/decay -> Manual Reset -> watch for re-trips.

Runs inside the ros_bridge_env container (it needs the CoppeliaSim remote
API and the bridge log). Start it through scripts/run_joint_test.sh, which
also fires the spike; this script only watches and does the reset.

It waits up to 60 s for "DEMO SPIKE triggered" in the bridge log and takes
that log stamp as t=0.

Exit code: 0 pass, 1 fail, 2 aborted (not ready, or no spike arrived).

Environment:
    ODOO_URL       default http://192.168.65.254:8069 (the Mac, seen from Docker)
    ODOO_DB        default admin
    ODOO_USERNAME  default admin
    ODOO_PASSWORD  required
    RESET_AT       seconds after the spike to Manual Reset, default 55
    WATCH_UNTIL    seconds after the spike to stop, default 100
"""
import os
import re
import sys
import time
import xmlrpc.client

from coppeliasim_zmqremoteapi_client import RemoteAPIClient

ODOO_URL = os.environ.get('ODOO_URL', 'http://192.168.65.254:8069')
ODOO_DB = os.environ.get('ODOO_DB', 'admin')
ODOO_USERNAME = os.environ.get('ODOO_USERNAME', 'admin')
ODOO_PASSWORD = os.environ.get('ODOO_PASSWORD')
RESET_AT = float(os.environ.get('RESET_AT', 55))
WATCH_UNTIL = float(os.environ.get('WATCH_UNTIL', 100))
BRIDGE_LOG = '/root/ros_bridge.log'
LOCATIONS = ['feed_pipeline', 'column_bottom', 'column_top', 'bottoms_output', 'distillate_output']


def say(text=''):
    print(text, flush=True)


if not ODOO_PASSWORD:
    sys.exit('ODOO_PASSWORD is not set')

uid = xmlrpc.client.ServerProxy(f'{ODOO_URL}/xmlrpc/2/common').authenticate(ODOO_DB, ODOO_USERNAME, ODOO_PASSWORD, {})
if not uid:
    sys.exit('Odoo login failed - check ODOO_DB / ODOO_USERNAME / ODOO_PASSWORD')
models = xmlrpc.client.ServerProxy(f'{ODOO_URL}/xmlrpc/2/object', allow_none=True)


def odoo(model, method, *args, **kwargs):
    return models.execute_kw(ODOO_DB, uid, ODOO_PASSWORD, model, method, list(args), kwargs)


sim = RemoteAPIClient('host.docker.internal').require('sim')
pipes = {p['name']: p for p in odoo('predictive.safety.pipeline', 'search_read', [('name', 'in', LOCATIONS)],
                                    fields=['name', 'design_pressure', 'current_status', 'valve_state'])}


def valve_closed(loc):
    return (sim.getFloatSignal(f'{loc}_valve_shutdown') or 0.0) > 0.5


def pressure_pct(loc):
    return 100 * (sim.getFloatSignal(f'{loc}_pressure') or 0.0) / pipes[loc]['design_pressure']


# Pre-flight: the scene must be playing, and every pipe must start SAFE and
# open, or the bridge refuses the spike
if sim.getSimulationState() != sim.simulation_advancing_running:
    say('NOT READY - the CoppeliaSim scene is not playing. Press Play, wait ~30 s, Manual Reset any tripped pipes, then run again.')
    sys.exit(2)
not_ready = [loc for loc in LOCATIONS
             if loc not in pipes or pipes[loc]['current_status'] != 'safe'
             or pipes[loc]['valve_state'] != 'open' or valve_closed(loc)]
if not_ready:
    say(f'NOT READY - not SAFE/open: {", ".join(not_ready)}. Press Manual Reset on them in Odoo, then run again.')
    sys.exit(2)
say('Pre-flight OK: all 5 pipes SAFE, all valves open.')

last_ticket = max(odoo('maintenance.request', 'search', []) or [0])
log_start = os.path.getsize(BRIDGE_LOG)
say('Waiting for DEMO SPIKE in the bridge log...')
spike_at = None
deadline = time.time() + 60
while spike_at is None and time.time() < deadline:
    with open(BRIDGE_LOG) as log:
        log.seek(log_start)
        for line in log.read().splitlines():
            if 'DEMO SPIKE' in line:
                say(f'Bridge: {line.strip()}')
                if 'triggered' not in line:
                    say('ABORTED - the bridge refused the spike.')
                    sys.exit(2)
                spike_at = float(re.search(r'\[(\d+\.\d+)\]', line).group(1))
    time.sleep(0.2)
if spike_at is None:
    say('ABORTED - no DEMO SPIKE within 60 s.')
    sys.exit(2)


def now():
    return time.time() - spike_at


say('Spike confirmed; t=0 is the bridge log stamp.\n')
closed = {loc: False for loc in LOCATIONS}
closed_at = {}
reopened = set()
retrips = []
reset_at = None
next_report = 5
while now() < WATCH_UNTIL:
    pct = {loc: pressure_pct(loc) for loc in LOCATIONS}
    for loc in LOCATIONS:
        is_closed = valve_closed(loc)
        if is_closed != closed[loc]:
            say(f't={now():6.1f}s  {loc:18} valve {"CLOSED" if is_closed else "opened"}  ({pct[loc]:.0f}% of design pressure)')
            if is_closed and reset_at is None:
                closed_at[loc] = now()
            elif is_closed:
                retrips.append(loc)
            else:
                reopened.add(loc)
            closed[loc] = is_closed
    if now() >= next_report:
        say(f't={now():6.1f}s  ' + '  '.join(
            f'{loc[:8]} {pct[loc]:3.0f}%{"(shut)" if closed[loc] else ""}' for loc in LOCATIONS))
        next_report += 5
    if reset_at is None and now() >= RESET_AT:
        reset_at = now()
        say(f'\nt={reset_at:6.1f}s  >>> MANUAL RESET on all 5\n')
        last_ticket = max(odoo('maintenance.request', 'search', []) or [0])
        for loc in LOCATIONS:
            try:
                odoo('predictive.safety.pipeline', 'reset_to_safe', [pipes[loc]['id']])
            except xmlrpc.client.Fault as fault:
                # the button method returns None, which XML-RPC can't send back
                if 'cannot marshal None' not in fault.faultString:
                    raise
    time.sleep(0.5)

new_tickets = odoo('maintenance.request', 'search_read', [('id', '>', last_ticket)], fields=['name']) if reset_at else []
final = {p['name']: p for p in odoo('predictive.safety.pipeline', 'search_read', [('name', 'in', LOCATIONS)],
                                    fields=['name', 'current_status', 'valve_state'])}

never_closed = [loc for loc in LOCATIONS if loc not in closed_at]
not_reopened = [loc for loc in LOCATIONS if loc not in reopened]
not_safe = [loc for loc in LOCATIONS if final[loc]['current_status'] != 'safe' or final[loc]['valve_state'] != 'open']

say('\n==== RESULT ====')
say('Closures:  ' + ', '.join(f'{loc} {closed_at[loc]:.1f}s' for loc in sorted(closed_at, key=closed_at.get)))
say(f'Never closed:           {never_closed or "none"}')
say(f'Not reopened by reset:  {not_reopened or "none"}')
say(f'Re-tripped after reset: {retrips or "none"}')
say(f'New tickets after reset: {[t["id"] for t in new_tickets] or "none"}')
say(f'Not SAFE/open at end:   {not_safe or "none"}')
failed = never_closed or not_reopened or retrips or new_tickets or not_safe
say('FAIL' if failed else 'PASS')
sys.exit(1 if failed else 0)

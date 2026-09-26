import json
import os
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import rclpy
from rclpy.node import Node
from std_msgs.msg import Empty
from coppeliasim_zmqremoteapi_client import RemoteAPIClient

# The 5 monitored locations - fixed names, matching coppeliasim/emergency_valve.lua
LOCATIONS = ['feed_pipeline', 'column_bottom', 'column_top', 'bottoms_output', 'distillate_output']

# Each location is its own Odoo equipment record, named exactly as above.
# Default is Docker Desktop's IPv4 address for the Mac host: host.docker.internal
# also resolves to IPv6 inside the container, which intermittently failed with
# "Network is unreachable". Override with the ODOO_URL environment variable.
ODOO_URL = os.environ.get('ODOO_URL', 'http://192.168.65.254:8069')

POLL_SEC = 0.1          # read all 15 signals every tick
HTTP_CYCLE_SEC = 1.0    # post each location's latest reading and read its valve command this often
STALE_THRESHOLD_SEC = 3.0  # if no good reading for this long, something's wrong
HTTP_TIMEOUT_SEC = 2.0


def fetch_json(req):
    # Docker Desktop occasionally drops a container->host connection; retry
    # once straight away on network errors. HTTP errors (e.g. 404) are real
    # answers from Odoo, so they're not retried
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SEC) as resp:
                return json.load(resp)
        except urllib.error.HTTPError:
            raise
        except OSError:
            if attempt == 2:
                raise


def odoo_jsonrpc(path, params):
    body = json.dumps({'jsonrpc': '2.0', 'method': 'call', 'params': params}).encode()
    reply = fetch_json(urllib.request.Request(f'{ODOO_URL}{path}', data=body, headers={'Content-Type': 'application/json'}))
    if 'error' in reply:
        raise RuntimeError(reply['error'].get('data', {}).get('message') or reply['error'])
    result = reply.get('result') or {}
    if 'error' in result:
        raise RuntimeError(result['error'])
    return result


def odoo_get(path):
    return fetch_json(urllib.request.Request(f'{ODOO_URL}{path}'))


class CoppeliaBridge(Node):
    def __init__(self):
        super().__init__('coppelia_bridge')

        # Demo trigger: publish std_msgs/Empty on /demo_spike to fire the shared
        # boil-up spike in CoppeliaSim (see emergency_valve.lua)
        self.spike_subscription = self.create_subscription(
            Empty,
            '/demo_spike',
            self.demo_spike_callback,
            10
        )

        # Connect to CoppeliaSim ZMQ remote API on the Mac host
        self.get_logger().info('Connecting to CoppeliaSim on macOS host...')
        self.client = RemoteAPIClient('host.docker.internal', 23000)
        self.sim = self.client.require('sim')
        self.get_logger().info(f'Connected! Relaying {len(LOCATIONS)} locations to Odoo at {ODOO_URL}')

        # Shared with the HTTP thread: latest complete reading per location
        # (written here) and the valve command Odoo wants (written there).
        # Only this node's own thread ever touches CoppeliaSim.
        self.lock = threading.Lock()
        self.latest = {}
        self.desired_commands = {}
        self.applied_commands = {}
        self.posts_ok = True
        self.commands_ok = True

        # Watchdog state: tracks the last time we got a real reading
        self.last_good_reading_time = time.time()
        self.warned_stale = False

        self.timer = self.create_timer(POLL_SEC, self.timer_callback)
        # Separate, slower timer just to check the watchdog
        self.watchdog_timer = self.create_timer(1.0, self.watchdog_callback)

        # Odoo calls run on their own thread, so a slow or failing Odoo can
        # never stall signal polling or valve updates
        self.http_thread = threading.Thread(target=self.http_loop, daemon=True)
        self.http_thread.start()

    def timer_callback(self):
        try:
            # Read all 15 signals; one shared timestamp per location per poll
            for location in LOCATIONS:
                temperature = self.sim.getFloatSignal(f'{location}_temperature')
                pressure = self.sim.getFloatSignal(f'{location}_pressure')
                flow = self.sim.getFloatSignal(f'{location}_flow_rate')
                if None in (temperature, pressure, flow):
                    continue
                shutdown = self.sim.getFloatSignal(f'{location}_valve_shutdown')
                reading = {
                    'location': location,
                    'temperature_f': float(temperature),
                    'pressure_psi': float(pressure),
                    'flow_gpm': float(flow),
                    'timestamp': datetime.now(timezone.utc).isoformat(),
                    'valve_position': 1.0 if shutdown and shutdown > 0.5 else 0.0,
                }
                with self.lock:
                    self.latest[location] = reading

            self.apply_valve_commands()

            if len(self.latest) == len(LOCATIONS):
                # Got a good reading - reset the watchdog
                self.last_good_reading_time = time.time()
                if self.warned_stale:
                    self.get_logger().info('>>> RECOVERED: all location signals are flowing again.')
                    self.warned_stale = False
        except Exception as e:
            self.get_logger().error(f'Failed to read location signals: {e}')

    def http_loop(self):
        while rclpy.ok():
            started = time.time()
            self.post_readings()
            self.fetch_valve_commands()
            time.sleep(max(0.0, HTTP_CYCLE_SEC - (time.time() - started)))

    def post_readings(self):
        with self.lock:
            readings = dict(self.latest)
        failed = None
        for location, payload in readings.items():
            try:
                odoo_jsonrpc(f'/api/live_readings/{location}', payload)
            except Exception as e:
                failed = f'{location}: {e}'
        if failed and self.posts_ok:
            self.get_logger().error(f'>>> NOT WORKING: failed to post readings to Odoo ({failed})')
        elif not failed and not self.posts_ok:
            self.get_logger().info('>>> RECOVERED: posting readings to Odoo again.')
        self.posts_ok = not failed

    def fetch_valve_commands(self):
        # Odoo holds each pipe's latched valve command (MATLAB verdicts,
        # Force Shutdown, Manual Reset); timer_callback applies them
        failed = None
        for location in LOCATIONS:
            try:
                command = odoo_get(f'/api/valve_commands/{location}').get('valve_command')
            except Exception as e:
                failed = f'{location}: {e}'
                continue
            if command in ('open', 'closed'):
                with self.lock:
                    self.desired_commands[location] = command
        if failed and self.commands_ok:
            self.get_logger().error(f'Failed to read valve commands from Odoo ({failed})')
        elif not failed and not self.commands_ok:
            self.get_logger().info('>>> RECOVERED: reading valve commands from Odoo again.')
        self.commands_ok = not failed

    def apply_valve_commands(self):
        # Runs on the node's thread - the only one that talks to CoppeliaSim
        with self.lock:
            desired = dict(self.desired_commands)
        for location, command in desired.items():
            if command == self.applied_commands.get(location):
                continue
            try:
                self.sim.setFloatSignal(f'{location}_valve_shutdown', 1.0 if command == 'closed' else 0.0)
                self.applied_commands[location] = command
                if command == 'closed':
                    self.get_logger().warn(f'VALVE SHUTDOWN RECEIVED: closing {location} valve!')
                else:
                    self.get_logger().info(f'VALVE SHUTDOWN CLEARED: opening {location} valve.')
            except Exception as e:
                self.get_logger().error(f'Failed to set {location}_valve_shutdown in simulation: {e}')

    def watchdog_callback(self):
        elapsed = time.time() - self.last_good_reading_time
        if elapsed > STALE_THRESHOLD_SEC and not self.warned_stale:
            missing = [l for l in LOCATIONS if l not in self.latest]
            self.get_logger().error(
                f'>>> NOT WORKING: no complete reading for all locations in {elapsed:.1f}s '
                f'(never seen: {missing or "none"}). Check that CoppeliaSim is running, the scene '
                'is playing, and the ZMQ remote API is reachable on host.docker.internal:23000.'
            )
            self.warned_stale = True

    def demo_spike_callback(self, msg):
        # The spike is one shared boil-up upset for the whole column, so it only
        # fires from a fully open state: if ANY location's valve is closed, the
        # whole spike is refused until Manual Reset in Odoo reopens everything
        try:
            closed = [l for l in LOCATIONS
                      if (self.sim.getFloatSignal(f'{l}_valve_shutdown') or 0.0) > 0.5]
            if closed:
                self.get_logger().warn(
                    f'DEMO SPIKE ignored: valve closed at {", ".join(closed)} - Manual Reset in Odoo first.')
                return
            self.sim.setFloatSignal('demo_spike', 1.0)
            self.get_logger().warn('DEMO SPIKE triggered: boil-up spike across all locations.')
        except Exception as e:
            self.get_logger().error(f'Failed to trigger demo spike in simulation: {e}')

def main(args=None):
    rclpy.init(args=args)
    bridge = CoppeliaBridge()
    try:
        rclpy.spin(bridge)
    except KeyboardInterrupt:
        pass
    finally:
        bridge.destroy_node()
        rclpy.shutdown()

if __name__ == '__main__':
    main()

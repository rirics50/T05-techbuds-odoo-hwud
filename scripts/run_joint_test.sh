#!/usr/bin/env bash
# One full safety-loop test from the Mac: starts the watcher in the
# ros_bridge_env container, fires the demo spike over ROS, and prints the
# PASS/FAIL result. Odoo, CoppeliaSim (scene playing), the bridge and
# Noel's MATLAB loop must all be running first.
#
# Usage:
#   ODOO_PASSWORD=... scripts/run_joint_test.sh
#   ODOO_PASSWORD=... RESET_AT=60 WATCH_UNTIL=120 scripts/run_joint_test.sh
set -u
: "${ODOO_PASSWORD:?set ODOO_PASSWORD first}"
CONTAINER=ros_bridge_env
OUT=$(mktemp)

docker cp "$(dirname "$0")/joint_test.py" "$CONTAINER:/root/joint_test.py" || exit 2

docker exec -e ODOO_PASSWORD -e ODOO_DB -e ODOO_USERNAME -e ODOO_URL -e RESET_AT -e WATCH_UNTIL \
    "$CONTAINER" timeout -s KILL 300 python3 -u /root/joint_test.py > >(tee "$OUT") 2>&1 &
WATCHER=$!

# Fire only once the watcher is listening for the spike
until grep -q -e 'Waiting for DEMO SPIKE' -e 'NOT READY' -e 'Error' -e 'failed' -e 'not set' "$OUT"; do
    kill -0 "$WATCHER" 2>/dev/null || break
    sleep 0.5
done
if grep -q 'Waiting for DEMO SPIKE' "$OUT"; then
    echo "Firing demo spike..."
    docker exec "$CONTAINER" timeout -s KILL 25 bash -c \
        "source /opt/ros/humble/setup.bash && ros2 topic pub --once /demo_spike std_msgs/msg/Empty '{}' >/dev/null 2>&1"
fi

wait "$WATCHER"
STATUS=$?
rm -f "$OUT"
exit $STATUS

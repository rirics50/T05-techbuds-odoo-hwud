"""Create or update the 5 monitored pipe records in Odoo with their specs
and per-location safety limits.

Safe to run repeatedly: records are matched by name, so an existing pipe
is updated in place rather than duplicated.

Usage:
    ODOO_PASSWORD=... python scripts/seed_equipment.py

Environment:
    ODOO_URL       default http://localhost:8069
    ODOO_DB        default admin
    ODOO_USERNAME  default admin
    ODOO_PASSWORD  required
"""
import os
import sys
import xmlrpc.client

ODOO_URL = os.environ.get('ODOO_URL', 'http://localhost:8069')
ODOO_DB = os.environ.get('ODOO_DB', 'admin')
ODOO_USERNAME = os.environ.get('ODOO_USERNAME', 'admin')
ODOO_PASSWORD = os.environ.get('ODOO_PASSWORD')

# All 5 locations use the same pipe spec
PIPE_SPEC = {
    'material': 'carbon_steel',
    'grade': 'API 5L X52',
    'diameter': 6.0,             # inches
    'thickness': 0.28,           # inches
    'corrosion_allowance': 0.125,  # inches
}

# Per-location limits, keyed by the fixed location names used in the scene
# and the API: design pressure (PSI), design temperature (F), flow limit
# (kg/s) and pipe length (m)
LOCATIONS = {
    'feed_pipeline':     {'design_pressure': 35.0, 'design_temperature': 105.0, 'flow_limit': 0.18, 'pipe_length': 25.0},
    'column_bottom':     {'design_pressure': 58.0, 'design_temperature': 200.0, 'flow_limit': 0.20, 'pipe_length': 5.0},
    'column_top':        {'design_pressure': 48.0, 'design_temperature': 163.0, 'flow_limit': 0.19, 'pipe_length': 8.0},
    'bottoms_output':    {'design_pressure': 57.0, 'design_temperature': 195.0, 'flow_limit': 0.20, 'pipe_length': 20.0},
    'distillate_output': {'design_pressure': 50.0, 'design_temperature': 165.0, 'flow_limit': 0.19, 'pipe_length': 30.0},
}


def main():
    if not ODOO_PASSWORD:
        sys.exit('Set ODOO_PASSWORD (and ODOO_URL / ODOO_DB / ODOO_USERNAME if not the defaults).')

    uid = xmlrpc.client.ServerProxy(f'{ODOO_URL}/xmlrpc/2/common').authenticate(
        ODOO_DB, ODOO_USERNAME, ODOO_PASSWORD, {})
    if not uid:
        sys.exit(f'Odoo login failed for {ODOO_USERNAME} on database {ODOO_DB}.')
    models = xmlrpc.client.ServerProxy(f'{ODOO_URL}/xmlrpc/2/object')

    def call(method, *args):
        return models.execute_kw(ODOO_DB, uid, ODOO_PASSWORD, 'predictive.safety.pipeline', method, list(args))

    for name, limits in LOCATIONS.items():
        values = {**PIPE_SPEC, **limits}
        existing = call('search', [('name', '=', name)])
        if existing:
            call('write', existing, values)
            print(f'updated {name}')
        else:
            call('create', {'name': name, **values})
            print(f'created {name}')


if __name__ == '__main__':
    main()

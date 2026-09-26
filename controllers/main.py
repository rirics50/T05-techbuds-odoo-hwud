from datetime import datetime, timezone

from odoo import http
from odoo.http import request
import json

# The 5 monitored locations; each is its own equipment record, named exactly this
LOCATIONS = ['feed_pipeline', 'column_bottom', 'column_top', 'bottoms_output', 'distillate_output']

# Engineering results MATLAB posts back per location (SI units)
ENGINEERING_RESULTS = ['velocity', 'reynolds_number', 'friction_factor',
                       'pressure_drop', 'temperature_rate', 'pressure_rate']


def _find_equipment(name):
    return request.env['predictive.safety.pipeline'].sudo().search([('name', '=', name)], limit=1)


def _json_response(data, status=200):
    return request.make_response(json.dumps(data), headers=[('Content-Type', 'application/json')], status=status)


def _not_found(name):
    return _json_response({'error': f'No equipment found with name "{name}"'}, status=404)


def _utc_iso(value):
    # Odoo stores naive UTC; tag it explicitly for MATLAB's datetime parsing
    return value.replace(tzinfo=timezone.utc).isoformat() if value else None


def _live_reading(equipment):
    """Same field names and raw units (F, PSI, gpm) as the bridge's payload"""
    return {
        'location': equipment.name,
        'temperature_f': equipment.temperature,
        'pressure_psi': equipment.last_pressure,
        'flow_gpm': equipment.flow_rate,
        'timestamp': _utc_iso(equipment.last_updated),
        'status': equipment.current_status,
        'valve_state': equipment.valve_state,
    }


class PredictiveSafetyController(http.Controller):

    @http.route('/api/equipment/<string:equipment_name>', type='http', auth='public', methods=['GET'], csrf=False)
    def get_equipment_spec(self, equipment_name, **kwargs):
        equipment = _find_equipment(equipment_name)
        if not equipment:
            return _not_found(equipment_name)

        return _json_response({
            'name': equipment.name,
            'material': equipment.material,
            'grade': equipment.grade,
            'diameter': equipment.diameter,
            'thickness': equipment.thickness,
            'corrosion_allowance': equipment.corrosion_allowance,
            'design_temperature': equipment.design_temperature,
            'design_pressure': equipment.design_pressure,
            'flow_limit': equipment.flow_limit,
            'pipe_length': equipment.pipe_length,
            'fluid_density': equipment.fluid_density,
            'fluid_viscosity': equipment.fluid_viscosity,
        })

    @http.route('/api/live_pressure/<string:equipment_name>', type='http', auth='public', methods=['GET'], csrf=False)
    def get_live_pressure(self, equipment_name, **kwargs):
        equipment = _find_equipment(equipment_name)
        if not equipment:
            return _not_found(equipment_name)

        # Newest logged reading (the model orders by timestamp desc)
        latest = request.env['predictive.safety.pressure.reading'].sudo().search(
            [('equipment_id', '=', equipment.id)], limit=1
        )
        return _json_response({
            'name': equipment.name,
            'pressure': equipment.last_pressure,
            'status': equipment.current_status,
            'valve_state': equipment.valve_state,
            'last_updated': _utc_iso(latest.timestamp) if latest else None,
        })

    @http.route('/api/safety_status/<string:equipment_name>', type='jsonrpc', auth='public', methods=['POST'], csrf=False)
    def post_safety_status(self, equipment_name, **kwargs):
        equipment = _find_equipment(equipment_name)
        if not equipment:
            return {'error': f'No equipment found with name "{equipment_name}"'}

        status = kwargs.get('status', '').lower()
        reason = kwargs.get('reason')

        if status not in ('safe', 'warning', 'critical'):
            return {'error': f'Invalid status "{status}" - must be safe, warning, or critical'}

        if not equipment.receive_safety_reading(status, pressure=equipment.last_pressure, reason=reason):
            return {
                'error': f'{equipment.name} is latched CRITICAL - Manual Reset in Odoo is required before new statuses apply',
                'status': equipment.current_status,
            }
        return {'ok': True, 'status': status}

    @http.route('/api/live_readings/<string:equipment_name>', type='jsonrpc', auth='public', methods=['POST'], csrf=False)
    def post_live_reading(self, equipment_name, **kwargs):
        """One pipe's live reading from ros_bridge.py:
        {location, temperature_f, pressure_psi, flow_gpm, timestamp[, valve_position]}"""
        equipment = _find_equipment(equipment_name)
        if not equipment:
            return {'error': f'No equipment found with name "{equipment_name}"'}
        if kwargs.get('location', equipment_name) != equipment_name:
            return {'error': f'Payload location "{kwargs.get("location")}" does not match "{equipment_name}"'}

        try:
            # ISO timestamp from the bridge; Odoo stores naive UTC
            stamp = datetime.fromisoformat(kwargs['timestamp']).astimezone(timezone.utc).replace(tzinfo=None)
            pressure = float(kwargs['pressure_psi'])
            values = {
                'temperature': float(kwargs['temperature_f']),
                'flow_rate': float(kwargs['flow_gpm']),
                'last_updated': stamp,
            }
            if kwargs.get('valve_position') is not None:
                values['valve_position'] = float(kwargs['valve_position'])
        except (KeyError, TypeError, ValueError) as e:
            return {'error': f'Bad reading payload: {e!r}'}

        # pressure also feeds this pipe's Pressure History chart
        equipment.log_pressure_reading(pressure)
        equipment.write(values)
        return {'ok': True, 'location': equipment_name}

    @http.route('/api/live_readings/<string:equipment_name>', type='http', auth='public', methods=['GET'], csrf=False)
    def get_live_reading(self, equipment_name, **kwargs):
        """Latest reading for one pipe, for Noel's MATLAB to poll"""
        equipment = _find_equipment(equipment_name)
        if not equipment:
            return _not_found(equipment_name)
        return _json_response(_live_reading(equipment))

    @http.route('/api/live_readings', type='http', auth='public', methods=['GET'], csrf=False)
    def get_all_live_readings(self, **kwargs):
        """Latest reading for all 5 pipes in one call, in LOCATIONS order"""
        pipes = request.env['predictive.safety.pipeline'].sudo().search([('name', 'in', LOCATIONS)])
        by_name = {p.name: p for p in pipes}
        return _json_response([_live_reading(by_name[name]) for name in LOCATIONS if name in by_name])

    @http.route('/api/valve_commands/<string:equipment_name>', type='http', auth='public', methods=['GET'], csrf=False)
    def get_valve_commands(self, equipment_name, **kwargs):
        """Latched status and valve command for one pipe, polled by ros_bridge.py"""
        equipment = _find_equipment(equipment_name)
        if not equipment:
            return _not_found(equipment_name)
        return _json_response({
            'name': equipment.name,
            'status': equipment.current_status,
            'valve_command': equipment.valve_state,
        })

    @http.route('/api/engineering_results/<string:location>', type='http', auth='public', methods=['POST'], csrf=False)
    def post_engineering_results(self, location, **kwargs):
        """MATLAB's computed results for one pipe, as a plain JSON body (not
        JSON-RPC): any of velocity (m/s), reynolds_number, friction_factor,
        pressure_drop (Pa), temperature_rate (K/s), pressure_rate (Pa/s).
        A missing or null value (e.g. no rate on the first reading) keeps the
        previous one. Errors return 400/404 so MATLAB's webwrite throws."""
        equipment = _find_equipment(location)
        if not equipment:
            return _not_found(location)

        try:
            payload = json.loads(request.httprequest.get_data() or b'{}')
        except ValueError:
            return _json_response({'error': 'Body must be JSON'}, status=400)
        if not isinstance(payload, dict):
            return _json_response({'error': 'Body must be a JSON object'}, status=400)

        values = {}
        for key in ENGINEERING_RESULTS:
            value = payload.get(key)
            if value is None:
                continue
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                return _json_response({'error': f'{key} must be a number, got {value!r}'}, status=400)
            values[key] = float(value)
        if not values:
            return _json_response({'error': f'No results given - expected any of {", ".join(ENGINEERING_RESULTS)}'}, status=400)

        equipment.write(values)
        return _json_response({'ok': True, 'location': equipment.name, 'updated': sorted(values)})

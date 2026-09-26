from odoo import http
from odoo.http import request
import json


def _find_equipment(name):
    return request.env['predictive.safety.pipeline'].sudo().search([('name', '=', name)], limit=1)


def _json_response(data, status=200):
    return request.make_response(json.dumps(data), headers=[('Content-Type', 'application/json')], status=status)


def _not_found(name):
    return _json_response({'error': f'No equipment found with name "{name}"'}, status=404)


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
        })

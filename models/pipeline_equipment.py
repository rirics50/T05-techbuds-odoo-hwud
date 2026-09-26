from odoo import models, fields


class PipelineEquipment(models.Model):
    _name = 'predictive.safety.pipeline'
    _description = 'Pipeline Equipment Specifications'

    name = fields.Char(string='Equipment ID', required=True, help="e.g., P-101")
    
    material = fields.Selection([
        ('carbon_steel', 'Carbon Steel'),
        ('stainless_steel', 'Stainless Steel'),
        ('alloy', 'Alloy')
    ], string='Material', required=True)
    
    grade = fields.Char(string='Material Grade', help="e.g., API 5L X52")
    diameter = fields.Float(string='Diameter (inches)', required=True)
    thickness = fields.Float(string='Wall Thickness (inches)', required=True)
    corrosion_allowance = fields.Float(string='Corrosion Allowance (inches)', default=0.125)
    
    design_temperature = fields.Float(string='Design Temperature (°F)', required=True)
    design_pressure = fields.Float(string='Design Pressure (PSI)', required=True)

    current_status = fields.Selection([
        ('safe', 'SAFE'),
        ('warning', 'WARNING'),
        ('critical', 'CRITICAL')
    ], string='Live Safety Status', default='safe', readonly=True)

    image = fields.Binary(string='Equipment Photo', attachment=True)

    valve_state = fields.Selection([
        ('open', 'Open'),
        ('closed', 'Closed'),
    ], string='Valve State', default='open', readonly=True)

    # Each record is one monitored location (feed_pipeline, column_bottom, ...)
    flow_limit = fields.Float(string='Flow Limit (kg/s)')
    pipe_length = fields.Float(string='Pipe Length (m)')

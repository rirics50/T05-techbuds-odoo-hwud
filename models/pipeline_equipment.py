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

    last_pressure = fields.Float(string='Current Pressure (PSI)', readonly=True)
    valve_state = fields.Selection([
        ('open', 'Open'),
        ('closed', 'Closed'),
    ], string='Valve State', default='open', readonly=True)

    # Each record is one monitored location (feed_pipeline, column_bottom, ...):
    # its static flow/length specs plus the live values ros_bridge.py posts
    # via /api/live_readings/<name>. Raw scene units - MATLAB converts.
    flow_limit = fields.Float(string='Flow Limit (kg/s)')
    pipe_length = fields.Float(string='Pipe Length (m)')
    temperature = fields.Float(string='Temperature (°F)', readonly=True)
    flow_rate = fields.Float(string='Flow Rate (gpm)', readonly=True)
    valve_position = fields.Float(string='Valve Position (0 open, 1 closed)', readonly=True)
    last_updated = fields.Datetime(string='Last Updated', readonly=True)

    def log_pressure_reading(self, pressure):
        """Called externally (via XML-RPC from safety_listener.py) for every
        live pressure reading. Feeds the dashboard chart only - never changes
        current_status or valve_state, which MATLAB decides."""
        self.ensure_one()
        # The bridge re-publishes the same held value ~10x/second, so only
        # log a reading when the value actually changes
        if pressure != self.last_pressure:
            self.env['predictive.safety.pressure.reading'].create({
                'equipment_id': self.id,
                'pressure': pressure,
            })
            self.last_pressure = pressure
        return True

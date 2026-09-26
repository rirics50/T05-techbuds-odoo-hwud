from markupsafe import Markup, escape

from odoo import api, models, fields

CHART_READINGS = 50


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

    reading_ids = fields.One2many('predictive.safety.pressure.reading', 'equipment_id', string='Pressure History')

    # Each record is one monitored location (feed_pipeline, column_bottom, ...):
    # its static flow/length specs plus the live values ros_bridge.py posts
    # via /api/live_readings/<name>. Raw scene units - MATLAB converts.
    flow_limit = fields.Float(string='Flow Limit (kg/s)')
    pipe_length = fields.Float(string='Pipe Length (m)')
    temperature = fields.Float(string='Temperature (°F)', readonly=True)
    flow_rate = fields.Float(string='Flow Rate (gpm)', readonly=True)
    valve_position = fields.Float(string='Valve Position (0 open, 1 closed)', readonly=True)
    last_updated = fields.Datetime(string='Last Updated', readonly=True)
    pressure_chart = fields.Html(string='Pressure Chart', compute='_compute_pressure_chart', sanitize=False)

    @api.depends('reading_ids.pressure', 'reading_ids.timestamp')
    def _compute_pressure_chart(self):
        """Inline SVG line chart of the latest readings - Odoo can't embed a
        graph view inside a form, so the form tab draws its own."""
        width, height, pad_left, pad_right, pad_y = 640, 220, 44, 12, 18
        for rec in self:
            readings = rec.reading_ids.sorted('timestamp')[-CHART_READINGS:]
            if len(readings) < 2:
                rec.pressure_chart = Markup('<p class="text-muted">Not enough readings yet to draw a chart.</p>')
                continue

            values = readings.mapped('pressure')
            reference = rec.design_pressure
            low = min(min(values), reference) - 2
            high = max(max(values), reference) + 2
            step = (width - pad_left - pad_right) / (len(values) - 1)

            def y(v):
                return pad_y + (high - v) / (high - low) * (height - 2 * pad_y)

            points = ' '.join(f'{pad_left + i * step:.1f},{y(v):.1f}' for i, v in enumerate(values))
            first = fields.Datetime.context_timestamp(rec, readings[0].timestamp).strftime('%H:%M:%S')
            last = fields.Datetime.context_timestamp(rec, readings[-1].timestamp).strftime('%H:%M:%S')
            limit_y = y(reference)
            rec.pressure_chart = Markup(
                f'<svg viewBox="0 0 {width} {height + 16}" style="width:100%;max-width:{width}px;font-size:11px" '
                f'role="img" aria-label="Pressure history line chart">'
                f'<line x1="{pad_left}" y1="{pad_y}" x2="{pad_left}" y2="{height - pad_y}" stroke="currentColor" stroke-opacity="0.3"/>'
                f'<line x1="{pad_left}" y1="{height - pad_y}" x2="{width - pad_right}" y2="{height - pad_y}" stroke="currentColor" stroke-opacity="0.3"/>'
                f'<text x="{pad_left - 6}" y="{pad_y + 4}" text-anchor="end" fill="currentColor">{high:.0f}</text>'
                f'<text x="{pad_left - 6}" y="{height - pad_y + 4}" text-anchor="end" fill="currentColor">{low:.0f}</text>'
                f'<line x1="{pad_left}" y1="{limit_y:.1f}" x2="{width - pad_right}" y2="{limit_y:.1f}" stroke="#dc3545" stroke-dasharray="5,4"/>'
                f'<text x="{width - pad_right}" y="{limit_y - 4:.1f}" text-anchor="end" fill="#dc3545">{reference:.0f} PSI design pressure</text>'
                f'<polyline points="{points}" fill="none" stroke="#0d6efd" stroke-width="2" stroke-linejoin="round"/>'
                f'<text x="{pad_left}" y="{height + 12}" fill="currentColor">{escape(first)}</text>'
                f'<text x="{width - pad_right}" y="{height + 12}" text-anchor="end" fill="currentColor">{escape(last)}</text>'
                f'</svg>'
            )

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

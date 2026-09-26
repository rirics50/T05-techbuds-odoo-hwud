from odoo import models, fields


class PressureReading(models.Model):
    _name = 'predictive.safety.pressure.reading'
    _description = 'Pressure Reading Log'
    _order = 'timestamp desc'

    equipment_id = fields.Many2one('predictive.safety.pipeline', string='Equipment', required=True, ondelete='cascade')
    pressure = fields.Float(string='Pressure (PSI)', aggregator='avg')
    timestamp = fields.Datetime(string='Reading Time', default=fields.Datetime.now)

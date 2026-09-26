{
    'name': 'Predictive Safety System',
    'version': '1.0',
    'summary': 'Equipment library and automated safety workflows',
    'category': 'Manufacturing/Maintenance',
    'depends': ['base', 'mail', 'maintenance'],
    'data': [
        'security/ir.model.access.csv',
        'views/equipment_views.xml',
    ],
    'assets': {
        'web.assets_backend': [
            'predictive_safety/static/src/scss/predictive_safety.scss',
        ],
    },
    'installable': True,
    'application': True,
}
function url = odoo_url(cfg, endpoint, location)
%ODOO_URL  Build a full Odoo URL from cfg.odoo_base_url.
%   url = odoo_url(cfg, 'safety_status', 'feed_pipeline')
%       -> <base>/api/safety_status/feed_pipeline
%   url = odoo_url(cfg, '/api/anything/else')          (plain path join)
%
%   Named endpoints (one Odoo record per location, addressed by location name):
%     'equipment'       /api/equipment/<location>       (limits and pipe spec, GET)
%     'safety_status'   /api/safety_status/<location>
%     'live_readings'   /api/live_readings/<location>
%     'valve_commands'  /api/valve_commands/<location>
%   An unknown name is an error rather than a guessed URL: a typo would
%   otherwise be a silent 404 at the worst moment.
%
%   MATLAB uses equipment (GET), live_readings (GET) and safety_status (POST).
%   valve_commands is polled by Riya's bridge, not by MATLAB; it is listed only
%   so the name is a known one.

    known = {'equipment', 'safety_status', 'live_readings', 'valve_commands'};

    if nargin < 3
        % Plain path form; tolerates a missing or doubled slash.
        url = [cfg.odoo_base_url '/' regexprep(endpoint, '^/+', '')];
        return
    end

    if ~any(strcmp(endpoint, known))
        error('odoo_url:unknownEndpoint', 'Unknown endpoint "%s"; expected one of: %s', ...
              endpoint, strjoin(known, ', '));
    end
    if isempty(location)
        error('odoo_url:noLocation', 'A location name is required for "%s"', endpoint);
    end
    url = [cfg.odoo_base_url '/api/' endpoint '/' location];
end

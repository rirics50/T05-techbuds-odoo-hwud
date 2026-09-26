function [limits, geometry, specs] = load_limits_from_odoo(locations, cfg, timeout_s)
%LOAD_LIMITS_FROM_ODOO  GET /api/equipment/<location> for each location (read-only).
%   [limits, geometry, specs] = load_limits_from_odoo(locations, cfg)
%   [limits, geometry, specs] = load_limits_from_odoo(locations, cfg, timeout_s)
%
%   locations  cell array of location names
%   limits     struct by location: pressure_bar, temperature_c, flow_kg_s
%   geometry   struct by location: pipe_diameter (m), pipe_length (m)
%   specs      struct by location: the raw Odoo record (for printing/logging)
%
%   Throws if ANY location fails, naming it. There is deliberately no silent
%   fallback to placeholder limits: judging safety against limits you did not
%   intend is worse than not starting.

    if nargin < 3
        timeout_s = 5;
    end
    limits = struct();  geometry = struct();  specs = struct();
    opts = weboptions('Timeout', timeout_s, 'ContentType', 'json');
    for k = 1:numel(locations)
        loc = locations{k};
        try
            spec = webread(odoo_url(cfg, 'equipment', loc), opts);
            [limits.(loc), geometry.(loc)] = limits_from_equipment(spec, loc);   % dynamic field name via (...)
            specs.(loc) = spec;
        catch err
            error('load_limits_from_odoo:failed', 'Could not load limits for %s: %s', loc, err.message);
        end
    end
end

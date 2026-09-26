% Headless test script for limits_from_equipment. NO network: it decodes JSON
% captured from Riya's live GET /api/equipment/<location> (2026-09-25).
% (load_limits_from_odoo is just webread + this, exercised by run_safety_loop_live.)
% Run: test_limits_from_equipment

throws = @(fn, id) throws_id(fn, id);
has = @(s, sub) ~isempty(strfind(s, sub));

% ---- Real records ----
recs.feed_pipeline     = '{"name": "feed_pipeline", "material": "carbon_steel", "grade": "API 5L X52", "diameter": 6.0, "thickness": 0.28, "corrosion_allowance": 0.125, "design_temperature": 100.0, "design_pressure": 35.0, "flow_limit": 0.18, "pipe_length": 25.0}';
recs.column_bottom     = '{"name": "column_bottom", "material": "carbon_steel", "grade": "API 5L X52", "diameter": 6.0, "thickness": 0.28, "corrosion_allowance": 0.125, "design_temperature": 180.0, "design_pressure": 58.0, "flow_limit": 0.2, "pipe_length": 5.0}';
recs.column_top        = '{"name": "column_top", "material": "carbon_steel", "grade": "API 5L X52", "diameter": 6.0, "thickness": 0.28, "corrosion_allowance": 0.125, "design_temperature": 146.0, "design_pressure": 48.0, "flow_limit": 0.19, "pipe_length": 8.0}';
recs.bottoms_output    = '{"name": "bottoms_output", "material": "carbon_steel", "grade": "API 5L X52", "diameter": 6.0, "thickness": 0.28, "corrosion_allowance": 0.125, "design_temperature": 178.0, "design_pressure": 57.0, "flow_limit": 0.2, "pipe_length": 20.0}';
recs.distillate_output = '{"name": "distillate_output", "material": "carbon_steel", "grade": "API 5L X52", "diameter": 6.0, "thickness": 0.28, "corrosion_allowance": 0.125, "design_temperature": 150.0, "design_pressure": 50.0, "flow_limit": 0.19, "pipe_length": 30.0}';

% ---- Conversions (column_bottom: 58 PSI, 180 F, 0.2 kg/s, 5 m, 6 in) ----
spec = jsondecode(recs.column_bottom);
[lim, geo] = limits_from_equipment(spec, 'column_bottom');
assert(abs(lim.pressure_bar - 58 * 0.0689476) < 1e-9);          % PSI -> bar
assert(abs(lim.temperature_c - (180 - 32) * 5 / 9) < 1e-9);     % F -> C = 82.222
assert(lim.flow_kg_s == 0.2);                                   % already SI, untouched
assert(abs(geo.pipe_diameter - 0.1524) < 1e-12);                % 6 in -> m
assert(geo.pipe_length == 5);

% ---- All five real records load into positive, finite SI values ----
names = fieldnames(recs);
for k = 1:numel(names)
    [lim, geo] = limits_from_equipment(jsondecode(recs.(names{k})), names{k});
    vals = [lim.pressure_bar lim.temperature_c lim.flow_kg_s geo.pipe_diameter geo.pipe_length];
    assert(all(isfinite(vals)) & all(vals > 0));
end

% ---- Bad records are rejected, never turned into a limit ----
good = jsondecode(recs.column_top);

zero = good;  zero.flow_limit = 0;                   % unset Odoo float reads as 0.0
assert(throws(@() limits_from_equipment(zero, 'column_top'), 'limits_from_equipment:badValue'));
neg = good;   neg.design_pressure = -5;
assert(throws(@() limits_from_equipment(neg, 'column_top'), 'limits_from_equipment:badValue'));
nul = good;   nul.pipe_length = [];                  % JSON null
assert(throws(@() limits_from_equipment(nul, 'column_top'), 'limits_from_equipment:badValue'));
txt = good;   txt.design_temperature = 'hot';
assert(throws(@() limits_from_equipment(txt, 'column_top'), 'limits_from_equipment:badValue'));
nan_ = good;  nan_.diameter = NaN;
assert(throws(@() limits_from_equipment(nan_, 'column_top'), 'limits_from_equipment:badValue'));

nofield = rmfield(good, 'flow_limit');
assert(throws(@() limits_from_equipment(nofield, 'column_top'), 'limits_from_equipment:missingField'));

assert(throws(@() limits_from_equipment(good, 'feed_pipeline'), 'limits_from_equipment:wrongLocation'));
assert(throws(@() limits_from_equipment(jsondecode('{"error": "No equipment found"}'), 'x'), ...
              'limits_from_equipment:odooError'));
assert(throws(@() limits_from_equipment('nope', 'x'), 'limits_from_equipment:badSpec'));

% The error message names the location and field so it is debuggable at the venue
try
    limits_from_equipment(zero, 'column_top');
catch err
    assert(has(err.message, 'column_top') & has(err.message, 'flow_limit'));
end

% ---- Snapshot check: what Odoo's REAL limits say about a real live reading ----
% Captured within seconds of each other: column_bottom read 180.03 F against a
% 180 F design limit. Documents that the design limits sit on the scene's own
% operating values (raised with Riya); if her limits change, update the snapshot.
live = jsondecode(['{"location": "column_bottom", "temperature_f": 180.03026594752444, ' ...
                   '"pressure_psi": 56.11123883901161, "flow_gpm": 2.7330727531109007, ' ...
                   '"timestamp": "2026-09-25T18:28:00.464397+00:00", "status": "safe", "valve_state": "open"}']);
raw = parse_live_reading(live, 'column_bottom');
[rd, fluid] = adapt_reading(raw, 0);
[lim, geo] = limits_from_equipment(jsondecode(recs.column_bottom), 'column_bottom');
pp = geo;  pp.fluid_density = fluid.fluid_density;  pp.fluid_viscosity = fluid.fluid_viscosity;
lims = struct('pressure_bar', lim.pressure_bar, 'temperature_c', lim.temperature_c, ...
              'flow_kg_s', lim.flow_kg_s);
r = combine_checks(rd, lims, pp);
assert(strcmp(r.status, 'CRITICAL'));                                  % temperature at/over its limit
assert(has(r.reason, 'Temperature:') & has(r.reason, 'Pressure:'));    % pressure is in its AT_RISK band
assert(~has(r.reason, 'Flow:'));                                        % 0.172 kg/s vs 0.18 margin: fine

% ---- Per-location geometry reaches check_flow through poll_cycle ----
cfg = struct('odoo_base_url', 'http://test:8069', 'rosbridge_url', 'ws://test:9090');
s = default_settings();
s.locations = {'column_bottom'};
s.limits = struct('column_bottom', struct('pressure_bar', 10, 'temperature_c', 150, 'flow_kg_s', 10));
s.pipe_geometry_by_location = struct('column_bottom', struct('pipe_diameter', 0.1524, 'pipe_length', 5));
s.fetch_fn = @(loc) struct('location', loc, 'pressure_psi', 30, 'temperature_F', 100, 'flow_gpm', 2);
s.send_fn  = @(u, p) deal(true, 'recorded');
[e, ~] = poll_cycle(cfg, s);
assert(strcmp(e(1).odoo_status, 'safe') & isempty(e(1).error));

disp('All limits_from_equipment tests passed.');

function tf = throws_id(fn, id)
    tf = false;
    try
        fn();
    catch err
        tf = strcmp(err.identifier, id);
    end
end

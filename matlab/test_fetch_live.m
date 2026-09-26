% Headless test script for parse_live_reading (the pure half of the live fetch).
% NO network: it decodes JSON captured from the real endpoint.
% (fetch_live_reading itself is just webread + this, and is exercised by
% run_safety_loop_live against Riya's live Odoo.) Run: test_fetch_live

has = @(s, sub) ~isempty(strfind(s, sub));
throws = @(fn, id) throws_id(fn, id);

% ---- Real response captured from GET /api/live_readings/column_bottom ----
real_json = ['{"location": "column_bottom", "temperature_f": 180.03026594752444, ' ...
             '"pressure_psi": 56.11123883901161, "flow_gpm": 2.7330727531109007, ' ...
             '"timestamp": "2026-09-25T18:28:00.464397+00:00", ' ...
             '"status": "safe", "valve_state": "open"}'];
resp = jsondecode(real_json);

raw = parse_live_reading(resp, 'column_bottom');
assert(strcmp(raw.location, 'column_bottom'));
assert(raw.temperature_F == 180.03026594752444);       % temperature_f -> temperature_F
assert(raw.pressure_psi == 56.11123883901161);
assert(raw.flow_gpm == 2.7330727531109007);
assert(strcmp(raw.timestamp, '2026-09-25T18:28:00.464397+00:00'));
% only the fields adapt_reading needs; Odoo's own status/valve_state are dropped
assert(isequal(sort(fieldnames(raw)), ...
               sort({'location';'temperature_F';'pressure_psi';'flow_gpm';'timestamp'})));

% ---- It feeds adapt_reading directly, including the real timestamp format ----
[rd, ~] = adapt_reading(raw, 1.7e9);
assert(strcmp(rd.timestamp_source, 'odoo_last_updated'));   % the reading's own stamp was used
expected = posixtime(datetime(2026, 9, 25, 18, 28, 0, 'TimeZone', 'UTC')) + 0.464397;
assert(abs(rd.timestamp - expected) < 1e-6);
assert(abs(rd.temperature - (180.03026594752444 - 32) * 5 / 9) < 1e-9);
assert(abs(rd.pressure - 56.11123883901161 * 0.0689476) < 1e-9);

% ---- Batch-style list element also works (same fields per element) ----
list = jsondecode(['[' real_json ',' strrep(real_json, 'column_bottom', 'column_top') ']']);
raw2 = parse_live_reading(list(2), 'column_top');
assert(strcmp(raw2.location, 'column_top'));

% ---- Record that has never received a reading: zeros + null timestamp ----
% This is the dangerous case (zeros would read SAFE), so it must be rejected.
never = jsondecode(['{"location": "column_top", "temperature_f": 0.0, "pressure_psi": 0.0, ' ...
                    '"flow_gpm": 0.0, "timestamp": null, "status": "safe", "valve_state": "open"}']);
assert(throws(@() parse_live_reading(never, 'column_top'), 'parse_live_reading:noReading'));

% ---- Other bad responses ----
assert(throws(@() parse_live_reading(jsondecode('{"error": "No equipment found"}'), 'x'), ...
              'parse_live_reading:odooError'));
assert(throws(@() parse_live_reading('not json', 'x'), 'parse_live_reading:notObject'));
assert(throws(@() parse_live_reading(jsondecode('[1,2,3]'), 'x'), 'parse_live_reading:notObject'));

missing = resp;  missing = rmfield(missing, 'flow_gpm');
assert(throws(@() parse_live_reading(missing, 'column_bottom'), 'parse_live_reading:missingField'));
no_ts = rmfield(resp, 'timestamp');
assert(throws(@() parse_live_reading(no_ts, 'column_bottom'), 'parse_live_reading:missingField'));

nonnum = resp;  nonnum.pressure_psi = 'high';
assert(throws(@() parse_live_reading(nonnum, 'column_bottom'), 'parse_live_reading:badValue'));
nullval = resp;  nullval.temperature_f = [];          % JSON null
assert(throws(@() parse_live_reading(nullval, 'column_bottom'), 'parse_live_reading:badValue'));

blank_ts = resp;  blank_ts.timestamp = '  ';
assert(throws(@() parse_live_reading(blank_ts, 'column_bottom'), 'parse_live_reading:noReading'));

% Asked for one location, got another
assert(throws(@() parse_live_reading(resp, 'feed_pipeline'), 'parse_live_reading:wrongLocation'));

% ---- Live URL is built from cfg via odoo_url ----
cfg = struct('odoo_base_url', 'http://192.168.0.134:8069');
assert(strcmp(odoo_url(cfg, 'live_readings', 'column_bottom'), ...
              'http://192.168.0.134:8069/api/live_readings/column_bottom'));

disp('All fetch_live / parse_live_reading tests passed.');

function tf = throws_id(fn, id)
    tf = false;
    try
        fn();
    catch err
        tf = strcmp(err.identifier, id);
    end
end

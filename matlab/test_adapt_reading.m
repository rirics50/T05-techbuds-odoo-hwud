% Headless test script for adapt_reading. Run: test_adapt_reading

POLL = 1.7e9;   % fixed fake poll time (epoch s) so results are deterministic
raw0 = struct('location', 'column_bottom', 'temperature_F', 212, ...
              'pressure_psi', 100, 'flow_gpm', 60);
tol = 1e-9;

% ---- Unit conversions ----
[r, fluid] = adapt_reading(raw0, POLL);
assert(abs(r.temperature - 100) < tol);                 % 212 F = 100 C
assert(abs(r.pressure - 6.89476) < tol);                % 100 PSI
assert(abs(r.flow_rate - 3.785411784) < tol);           % 60 gpm * 1000 kg/m^3
assert(strcmp(r.location, 'column_bottom'));

raw = raw0;  raw.temperature_F = 32;
r = adapt_reading(raw, POLL);
assert(abs(r.temperature - 0) < tol);                   % freezing point
raw.temperature_F = -40;
r = adapt_reading(raw, POLL);
assert(abs(r.temperature - (-40)) < tol);               % F and C meet at -40

% Zero stays zero
raw = raw0;  raw.pressure_psi = 0;  raw.flow_gpm = 0;
r = adapt_reading(raw, POLL);
assert(r.pressure == 0 & r.flow_rate == 0);

% ---- Fluid placeholders exposed for pipe_params ----
assert(fluid.fluid_density == 1000 & fluid.fluid_viscosity == 0.001);

% ---- Timestamp: absent -> MATLAB poll time ----
r = adapt_reading(raw0, POLL);
assert(r.timestamp == POLL & strcmp(r.timestamp_source, 'matlab_poll'));

% ---- Timestamp: present -> last_updated wins ----
raw = raw0;  raw.last_updated = '2026-01-01T00:00:00+00:00';
r = adapt_reading(raw, POLL);
assert(r.timestamp == 1767225600 & strcmp(r.timestamp_source, 'odoo_last_updated'));
% independent cross-check of that constant
assert(r.timestamp == posixtime(datetime(2026, 1, 1, 'TimeZone', 'UTC')));

% Fractional seconds (Python isoformat with microseconds)
raw.last_updated = '2026-01-01T00:00:00.500000+00:00';
r = adapt_reading(raw, POLL);
assert(abs(r.timestamp - 1767225600.5) < 1e-6);

% 'Z' suffix and naive (no offset) both read as UTC
raw.last_updated = '2026-01-01T00:00:00Z';
r = adapt_reading(raw, POLL);
assert(r.timestamp == 1767225600);
raw.last_updated = '2026-01-01T00:00:00';
r = adapt_reading(raw, POLL);
assert(r.timestamp == 1767225600);

% datetime object and numeric epoch are accepted
raw.last_updated = datetime(2026, 1, 1, 'TimeZone', 'UTC');
r = adapt_reading(raw, POLL);
assert(r.timestamp == 1767225600);
raw.last_updated = 1767225600;
r = adapt_reading(raw, POLL);
assert(r.timestamp == 1767225600);

% ---- 'timestamp' is Odoo's real field name and is preferred over last_updated ----
raw = raw0;  raw.timestamp = '2026-01-01T00:00:00.500000+00:00';
r = adapt_reading(raw, POLL);
assert(abs(r.timestamp - 1767225600.5) < 1e-6 & strcmp(r.timestamp_source, 'odoo_last_updated'));
raw.last_updated = '2026-01-01T00:00:10+00:00';          % both present: timestamp wins
r = adapt_reading(raw, POLL);
assert(abs(r.timestamp - 1767225600.5) < 1e-6);
raw.timestamp = 'garbage';                               % bad timestamp -> falls back to last_updated
r = adapt_reading(raw, POLL);
assert(r.timestamp == 1767225610);
raw.last_updated = 'garbage';                            % both bad -> poll time
r = adapt_reading(raw, POLL);
assert(r.timestamp == POLL & strcmp(r.timestamp_source, 'matlab_poll'));

% ---- Timestamp: unusable last_updated falls back to poll time, no crash ----
bad = {[], '', 'not a date', '2026-13-45T00:00:00+00:00', ...
       '2026-01-01T00:00:00+05:30', NaN, {}};   % non-UTC offset must NOT be read as UTC
for k = 1:numel(bad)
    raw = raw0;  raw.last_updated = bad{k};
    r = adapt_reading(raw, POLL);
    assert(r.timestamp == POLL & strcmp(r.timestamp_source, 'matlab_poll'));
end

% ---- Default poll time is "now" (within a sane window) ----
before = posixtime(datetime('now', 'TimeZone', 'UTC'));
r = adapt_reading(raw0);
after = posixtime(datetime('now', 'TimeZone', 'UTC'));
assert(r.timestamp >= before & r.timestamp <= after);

% ---- valve_position passes through only when present ----
raw = raw0;  raw.valve_position = 40;
r = adapt_reading(raw, POLL);
assert(r.valve_position == 40);
r = adapt_reading(raw0, POLL);
assert(~isfield(r, 'valve_position'));

% ---- Missing / non-numeric values become NaN, never an error ----
raw = struct('location', 'column_top', 'temperature_F', 200);   % no pressure, no flow
r = adapt_reading(raw, POLL);
assert(isnan(r.pressure) & isnan(r.flow_rate) & isfinite(r.temperature));
raw = raw0;  raw.pressure_psi = 'oops';
r = adapt_reading(raw, POLL);
assert(isnan(r.pressure));

% ---- Output is directly usable by the check_* functions, unchanged ----
pp = struct('pipe_diameter', 0.1, 'pipe_length', 10, ...
            'fluid_density', fluid.fluid_density, 'fluid_viscosity', fluid.fluid_viscosity);
r = adapt_reading(raw0, POLL);
p = check_pressure(r, 10);       % 6.89 bar vs 10 bar limit
t = check_temperature(r, 150);   % 100 C vs 150 C limit
f = check_flow(r, 10, pp);       % 3.79 kg/s vs 10 kg/s limit
assert(strcmp(p.status, 'SAFE') & strcmp(t.status, 'SAFE') & strcmp(f.status, 'SAFE'));
assert(isfinite(f.reynolds_number));

% A NaN produced by adaptation makes the check fail safe
raw = raw0;  raw.pressure_psi = NaN;
r = adapt_reading(raw, POLL);
p = check_pressure(r, 10);
assert(strcmp(p.status, 'CRITICAL') & strcmp(p.action, 'SHUTDOWN'));

disp('All adapt_reading tests passed.');

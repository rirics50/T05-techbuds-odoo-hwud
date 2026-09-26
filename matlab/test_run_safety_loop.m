% Headless test script for the polling wrapper (poll_cycle, run_safety_loop,
% default_settings). No network: sending is stubbed or recorded. Run: test_run_safety_loop

cfg = struct('odoo_base_url', 'http://test:8069', 'rosbridge_url', 'ws://test:9090');
locs = {'feed_pipeline', 'column_bottom', 'column_top', 'bottoms_output', 'distillate_output'};
has = @(s, sub) ~isempty(strfind(s, sub));

% ---- Shared fake "world" (containers.Map is a handle, so tests can mutate it) ----
normal = struct('pressure_psi', 30, 'temperature_F', 100, 'flow_gpm', 2);
world = containers.Map();
world('raw')  = make_world(locs, normal);
world('fail') = {};
clk = containers.Map();
clk('now') = 1000;
rec = containers.Map();

settings = default_settings();
settings.fetch_fn = @(loc) world_fetch(world, loc);
settings.now_fn   = @() clk('now');
settings.send_fn  = @(u, p) record_send(rec, u, p);
settings.verbose  = false;
% Generous limits so these tests don't depend on the placeholder limits
for k = 1:numel(locs)
    settings.limits.(locs{k}) = struct('pressure_bar', 10, 'temperature_c', 150, 'flow_kg_s', 10);
end

% ---- default_settings sanity ----
d = default_settings();
assert(isequal(d.locations, locs));
for k = 1:numel(locs)
    L = d.limits.(locs{k});
    assert(all(isfinite([L.pressure_bar L.temperature_c L.flow_kg_s])));
end
assert(abs(d.limits.column_bottom.pressure_bar - 62 * 0.0689476) < 1e-9);   % converted via adapt_reading
assert(d.send_http == false);       % network is off unless explicitly enabled

% ---- Cycle 1: everything normal, no previous readings ----
[e, state] = poll_cycle(cfg, settings);
assert(numel(e) == 5);
assert(isequal({e.location}, locs));
assert(all(strcmp({e.odoo_status}, 'safe')));
assert(all([e.sent]) & ~any([e.skipped]));
assert(rec.Count == 5);
% URL built from cfg via odoo_url, one per location
assert(strcmp(e(1).url, 'http://test:8069/api/safety_status/feed_pipeline'));
assert(strcmp(e(4).url, 'http://test:8069/api/safety_status/bottoms_output'));
% payload shape sent to the (recorded) endpoint
call = rec('1');
assert(strcmp(call.url, e(1).url) & strcmp(call.payload.status, 'safe'));
assert(call.payload.shutdown_signal == 0);

% ---- Default sender is a stub: nothing is sent, but the cycle still succeeds ----
s2 = settings;  s2.send_fn = [];
[e2, ~] = poll_cycle(cfg, s2);
assert(all([e2.sent]) & has(e2(1).send_msg, 'stub'));

% ---- Cycle 2: spike on ONE location -> only that one goes critical ----
clk('now') = 1001;
w = world('raw');
w.column_bottom.pressure_psi = 200;      % 13.8 bar, over the 10 bar limit
world('raw') = w;
rec.remove(rec.keys());                  % clear the recorder
[e, state] = poll_cycle(cfg, settings, state);
cb = e(2);
assert(strcmp(cb.location, 'column_bottom'));
assert(strcmp(cb.status, 'CRITICAL') & strcmp(cb.odoo_status, 'critical'));
assert(cb.shutdown_signal == 1 & cb.valve_command == 0 & has(cb.reason, 'Pressure:'));
others = e([1 3 4 5]);
assert(all(strcmp({others.odoo_status}, 'safe')));

% ---- Previous reading is kept per location: a fast rise trips the rate check ----
world('raw') = make_world(locs, normal);
clk('now') = 1002;
[~, state] = poll_cycle(cfg, settings, state);          % settle everything back to normal
w = world('raw');
w.column_top.pressure_psi = 60;                          % 30 -> 60 PSI in 1 s
world('raw') = w;
clk('now') = 1003;
[e, state] = poll_cycle(cfg, settings, state);
ct = e(3);
assert(strcmp(ct.location, 'column_top'));
assert(strcmp(ct.status, 'AT_RISK') & strcmp(ct.odoo_status, 'warning'));
assert(has(ct.reason, 'dP/dt'));
% ADJUST_VALVE is informational only: text note, never a shutdown signal
assert(ct.shutdown_signal == 0 & has(ct.reason, 'would adjust valve to 50%'));
% the other four had no jump, so they are unaffected (history is per location)
assert(all(strcmp({e([1 2 4 5]).odoo_status}, 'safe')));

% ---- Idle baseline with WORST-CASE noise, DEFAULT limits and thresholds ----
% Regression test for the two tuning bugs: (1) the Kelvin margin left hot
% locations in permanent 'warning', (2) rate limits below the scene's noise
% caused false trips. Baselines and noise ranges are from the Lua scene:
% temp +/-1 F, pressure +/-0.5 PSI, flow +/-0.3 gpm. Noise alternates between
% the two extremes each second, the largest possible consecutive-sample swing.
base = struct( ...
    'feed_pipeline',     [ 90  30 2.0], ...   % [temp_F  press_psi  flow_gpm]
    'column_bottom',     [170  49 2.2], ...
    'column_top',        [135  40 1.8], ...
    'bottoms_output',    [165  48 2.2], ...
    'distillate_output', [140  42 1.8]);
noise = [1 0.5 0.3];
sd = default_settings();                  % default limits AND default thresholds
sd.fetch_fn = @(loc) world_fetch(world, loc);
sd.now_fn   = @() clk('now');
sd.send_fn  = @(u, p) record_send(rec, u, p);
sd.verbose  = false;
state_b = [];
for cyc = 1:6
    sgn = 1 - 2 * mod(cyc, 2);            % +1, -1, +1, ...
    w = struct();
    for k = 1:numel(locs)
        v = base.(locs{k}) + sgn * noise;
        w.(locs{k}) = struct('temperature_F', v(1), 'pressure_psi', v(2), 'flow_gpm', v(3));
    end
    world('raw') = w;
    clk('now') = 2000 + cyc;              % 1 s apart
    [e, state_b] = poll_cycle(cfg, sd, state_b);
    assert(all(strcmp({e.odoo_status}, 'safe')));   % no warning, no false rate trip
end

% ---- Top of a full spike (minus worst-case noise) DOES trip every location ----
top = struct( ...
    'feed_pipeline',     [105  38 2.8], ...   % base + range from the Lua scene
    'column_bottom',     [192  63 3.2], ...
    'column_top',        [155  52 3.0], ...
    'bottoms_output',    [187  62 3.2], ...
    'distillate_output', [160  54 3.0]);
w = struct();
for k = 1:numel(locs)
    v = top.(locs{k}) - noise;
    w.(locs{k}) = struct('temperature_F', v(1), 'pressure_psi', v(2), 'flow_gpm', v(3));
end
world('raw') = w;
clk('now') = 2100;
[e, ~] = poll_cycle(cfg, sd);
assert(all(strcmp({e.odoo_status}, 'critical')) & all([e.shutdown_signal] == 1));
world('raw') = make_world(locs, normal);    % restore for the tests below

% ---- Send failure: recorded, cycle survives, next cycle still has history ----
s3 = settings;  s3.send_fn = @(u, p) deal(false, 'HTTP 500');
w = world('raw');  w.column_top.pressure_psi = 30;  world('raw') = w;
clk('now') = 1004;
[e, state] = poll_cycle(cfg, s3, state);
assert(~any([e.sent]) & has(e(1).send_msg, 'HTTP 500'));
assert(all(strcmp({e.odoo_status}, 'safe')));           % decisions still made

% ---- Fetch failure: skip until max_fetch_failures, then fail safe ----
world('fail') = {'feed_pipeline'};
state = [];
[e, state] = poll_cycle(cfg, settings, state);          % failure 1 of 3
assert(e(1).skipped & ~e(1).sent & isempty(e(1).odoo_status) & has(e(1).error, 'fetch failed'));
assert(all(strcmp({e(2:5).odoo_status}, 'safe')));      % other locations unaffected
[e, state] = poll_cycle(cfg, settings, state);          % failure 2
assert(e(1).skipped);
[e, state] = poll_cycle(cfg, settings, state);          % failure 3 -> bad data
assert(~e(1).skipped & strcmp(e(1).status, 'CRITICAL') & e(1).shutdown_signal == 1);
assert(has(e(1).reason, 'Invalid'));
% recovery resets the counter
world('fail') = {};
[e, state] = poll_cycle(cfg, settings, state);
assert(strcmp(e(1).odoo_status, 'safe'));
world('fail') = {'feed_pipeline'};
[e, ~] = poll_cycle(cfg, settings, state);              % failure 1 again, not 4
assert(e(1).skipped);
world('fail') = {};

% ---- Frozen data: an unchanged timestamp must not look SAFE forever ----
% (bridge dies -> Odoo keeps returning the last values with the same timestamp)
stamped = make_world(locs, struct('pressure_psi', 30, 'temperature_F', 100, ...
                                  'flow_gpm', 2, 'timestamp', '2026-09-25T18:00:00+00:00'));
world('raw') = stamped;
state = [];
for n = 1:5                                             % same stamp 5 polls in a row
    clk('now') = 3000 + n;
    [e, state] = poll_cycle(cfg, settings, state);
    assert(all(strcmp({e.odoo_status}, 'safe')));       % up to max_stale_polls (5) still fine
end
clk('now') = 3006;
[e, state] = poll_cycle(cfg, settings, state);          % 6th: stale, failure 1 of 3
assert(all([e.skipped]) & has(e(1).error, 'unchanged'));
[e, state] = poll_cycle(cfg, settings, state);          % failure 2
assert(all([e.skipped]));
[e, state] = poll_cycle(cfg, settings, state);          % failure 3 -> fail safe
assert(all(strcmp({e.odoo_status}, 'critical')) & all([e.shutdown_signal] == 1));
assert(has(e(1).reason, 'No usable sensor data') & has(e(1).reason, 'unchanged'));
% a new timestamp resets everything
w = stamped;
for k = 1:numel(locs)
    w.(locs{k}).timestamp = '2026-09-25T18:00:07+00:00';
end
world('raw') = w;
[e, state] = poll_cycle(cfg, settings, state);
assert(all(strcmp({e.odoo_status}, 'safe')));
% readings with no timestamp at all (like the fake data above) are never stale
world('raw') = make_world(locs, normal);
state = [];
for n = 1:8
    [e, state] = poll_cycle(cfg, settings, state);
end
assert(all(strcmp({e.odoo_status}, 'safe')));

% ---- One location's bug does not stop the others ----
s4 = settings;
s4.limits = rmfield(s4.limits, 'column_top');
[e, ~] = poll_cycle(cfg, s4);
assert(~isempty(e(3).error) & ~e(3).sent);
assert(all(strcmp({e([1 2 4 5]).odoo_status}, 'safe')));

% ---- fetch_fn is mandatory ----
s5 = settings;  s5.fetch_fn = [];
threw = false;
try
    poll_cycle(cfg, s5);
catch err
    threw = strcmp(err.identifier, 'poll_cycle:noFetch');
end
assert(threw);

% ---- run_safety_loop: N iterations, load_config called once when cfg omitted ----
rec.remove(rec.keys());
s6 = settings;  s6.max_iterations = 3;  s6.poll_interval_s = 0;
[history, ~] = run_safety_loop(s6, cfg);
assert(numel(history) == 3 & rec.Count == 15);          % 3 cycles x 5 locations

real_cfg = load_config();
rec.remove(rec.keys());
s7 = settings;  s7.max_iterations = 1;  s7.poll_interval_s = 0;
[history, ~] = run_safety_loop(s7);                     % no cfg passed -> config.json
assert(strcmp(history{1}(1).url, odoo_url(real_cfg, '/api/safety_status/feed_pipeline')));

% ---- A crashing cycle does not kill the loop ----
s8 = settings;  s8.max_iterations = 2;  s8.poll_interval_s = 0;
s8.fetch_fn = [];                                       % poll_cycle throws every time
[history, ~] = run_safety_loop(s8, cfg);
assert(isempty(history));                               % nothing logged, but it returned

disp('All run_safety_loop tests passed.');

% ---- local helpers ----
function w = make_world(locs, raw)
    for k = 1:numel(locs)
        w.(locs{k}) = raw;
    end
end

function raw = world_fetch(world, loc)
    if ismember(loc, world('fail'))
        error('sim:down', 'sensor down');
    end
    tbl = world('raw');
    raw = tbl.(loc);
end

function [ok, msg] = record_send(rec, url, payload)
    rec(sprintf('%d', rec.Count + 1)) = struct('url', url, 'payload', payload);
    ok  = true;
    msg = 'recorded';
end

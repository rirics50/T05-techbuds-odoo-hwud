% Headless test script for the dashboard DATA layer, the periodic limits reload
% and the loop hooks. No figure is opened and there is no network: rendering
% (dashboard_create / dashboard_render) needs a display and is checked by eye.
% Run: test_dashboard

cfg = struct('odoo_base_url', 'http://test:8069', 'rosbridge_url', 'ws://test:9090');
locs = {'feed_pipeline', 'column_bottom', 'column_top', 'bottoms_output', 'distillate_output'};
has = @(s, sub) ~isempty(strfind(s, sub));
GREEN = [0.78 0.92 0.78];  AMBER = [1.00 0.90 0.60];  RED = [0.98 0.68 0.68];  GRAY = [0.85 0.85 0.85];

% ---- fake world ----
normal = struct('pressure_psi', 30, 'temperature_F', 100, 'flow_gpm', 2, ...
                'timestamp', '2026-09-25T18:00:00+00:00');
world = containers.Map();
world('raw')  = make_world(locs, normal);
world('fail') = {};
clk = containers.Map();  clk('now') = 1000;

settings = default_settings();
settings.fetch_fn = @(loc) world_fetch(world, loc);
settings.now_fn   = @() clk('now');
settings.send_fn  = @(u, p) deal(true, 'recorded');
settings.verbose  = false;
settings.max_iterations = 3;
settings.poll_interval_s = 0;
loose = struct('pressure_bar', 10, 'temperature_c', 150, 'flow_kg_s', 10);
for k = 1:numel(locs)
    settings.limits.(locs{k}) = loose;
end
settings.limits_reload_fn = [];   % fixed limits unless a test sets a reload function

info0 = struct('iteration', 1, 'now_s', 1000, 'cfg', cfg, 'send_http', false, 'opts', struct(), ...
               'limits', settings.limits, 'limits_age_s', 0, 'limits_reloading', false, ...
               'limits_reload_interval_s', 30, 'limits_fail_count', 0, 'limit_changes', {{}});

% ============================ entries carry display data ============================
[e, state] = poll_cycle(cfg, settings);
assert(e(1).poll_time_s == 1000);
assert(abs(e(1).reading.pressure - 30 * 0.0689476) < 1e-9);
assert(e(1).raw.pressure_psi == 30);
assert(e(1).limits.pressure_bar == 10);
% these extra fields never change a decision
assert(all(strcmp({e.odoo_status}, 'safe')));

% ============================ table rows ============================
model = dashboard_update([], e, info0);
assert(isequal(size(model.rows), [5 7]) & numel(model.columns) == 7);
assert(isequal(model.locations, locs));
assert(strcmp(model.rows{1, 1}, 'SAFE'));
assert(strcmp(model.rows{1, 2}, '100.0 F | 37.8 C'));
assert(strcmp(model.rows{1, 3}, '30.0 PSI | 2.07 bar'));
assert(strcmp(model.rows{1, 4}, '2.00 gpm | 0.126 kg/s'));
assert(strcmp(model.rows{1, 5}, '150.0 C | 10.00 bar | 10.000 kg/s'));
assert(strcmp(model.rows{1, 6}, '0.0 s'));
assert(strcmp(model.rows{1, 7}, 'All checks SAFE'));
assert(isequal(model.row_colors(1, :), GREEN));

% ---- statuses and reasons come from the loop unchanged; colours follow status ----
w = world('raw');
w.column_top.pressure_psi = 135;      % 9.31 bar: inside the AT_RISK band (9 to 10)
w.column_bottom.pressure_psi = 150;   % 10.34 bar: over the limit
world('raw') = w;
[e, ~] = poll_cycle(cfg, settings);
model = dashboard_update([], e, info0);
assert(strcmp(model.rows{3, 1}, 'AT_RISK') & isequal(model.row_colors(3, :), AMBER));
assert(strcmp(model.rows{2, 1}, 'CRITICAL') & isequal(model.row_colors(2, :), RED));
assert(isequal(model.row_colors(1, :), GREEN));
for k = 1:5
    assert(strcmp(model.rows{k, 7}, e(k).reason));      % reason is passed through verbatim
    assert(strcmp(model.rows{k, 1}, e(k).status));
end
world('raw') = make_world(locs, normal);

% ============================ reading age ============================
% age = seconds since the timestamp last CHANGED, by our own clock
mk_ts = @(s) struct('pressure_psi', 30, 'temperature_F', 100, 'flow_gpm', 2, ...
                    'timestamp', sprintf('2026-09-25T18:00:%02d+00:00', s));
clk('now') = 2000;  world('raw') = make_world(locs, mk_ts(1));
[e, st] = poll_cycle(cfg, settings);
m = dashboard_update([], e, setfield(info0, 'now_s', 2000));
assert(strcmp(m.rows{1, 6}, '0.0 s'));
clk('now') = 2001;                                          % same timestamp again
[e, st] = poll_cycle(cfg, settings, st);
m = dashboard_update(m, e, setfield(info0, 'now_s', 2001));
assert(strcmp(m.rows{1, 6}, '1.0 s'));
clk('now') = 2002;                                          % still the same
[e, st] = poll_cycle(cfg, settings, st);
m = dashboard_update(m, e, setfield(info0, 'now_s', 2002));
assert(strcmp(m.rows{1, 6}, '2.0 s'));
clk('now') = 2003;  world('raw') = make_world(locs, mk_ts(4));   % new timestamp resets it
[e, st] = poll_cycle(cfg, settings, st);
m = dashboard_update(m, e, setfield(info0, 'now_s', 2003));
assert(strcmp(m.rows{1, 6}, '0.0 s'));
world('raw') = make_world(locs, normal);  clk('now') = 1000;

% ============================ history buffer ============================
[e, ~] = poll_cycle(cfg, settings);
m = [];
for n = 0:129
    m = dashboard_update(m, e, setfield(info0, 'now_s', 1000 + n));
end
assert(numel(m.t.feed_pipeline) == 120);                    % capped
assert(m.t.feed_pipeline(end) == 129 & m.t.feed_pipeline(1) == 10);
assert(numel(m.series.feed_pipeline.pressure_bar) == 120);
assert(numel(m.series.column_top.temperature_c) == numel(m.t.column_top));
assert(m.xlim(2) == 129 & m.xlim(1) == 9);

% ============================ chart lines: limit, band, y-range ============================
assert(m.limit.feed_pipeline.temperature_c == 150 & m.limit.feed_pipeline.pressure_bar == 10);
assert(abs(m.band.feed_pipeline.temperature_c - 135) < 1e-12);       % 90% of the limit in C
assert(abs(m.band.feed_pipeline.pressure_bar - 9) < 1e-12);
assert(abs(m.band.feed_pipeline.flow_kg_s - 9) < 1e-12);
yr = m.ylim.feed_pipeline.temperature_c;
assert(yr(2) > 150 & yr(1) < 37.8);                                   % covers the data AND the limit
% a margin override changes the drawn band
mo = dashboard_update([], e, setfield(info0, 'opts', struct('margin_fraction', 0.8)));
assert(abs(mo.band.feed_pipeline.pressure_bar - 8) < 1e-12);

% ============================ no data / fail-safe rows ============================
world('fail') = {'feed_pipeline'};
[e, sf] = poll_cycle(cfg, settings);                        % failure 1 of 3: skipped
m = dashboard_update([], e, info0);
assert(strcmp(m.rows{1, 1}, 'NO DATA') & isequal(m.row_colors(1, :), GRAY));
assert(has(m.rows{1, 7}, 'fetch failed'));
assert(strcmp(m.rows{1, 2}, 'n/a F | n/a C') & strcmp(m.rows{1, 6}, 'n/a'));
assert(strcmp(m.rows{2, 1}, 'SAFE'));                       % the others are unaffected
assert(isnan(m.series.feed_pipeline.pressure_bar(end)));    % gap in the line, no crash
[e, sf] = poll_cycle(cfg, settings, sf);                    % failure 2
[e, sf] = poll_cycle(cfg, settings, sf);                    % failure 3 -> fail-safe CRITICAL
m = dashboard_update(m, e, info0);
assert(strcmp(m.rows{1, 1}, 'CRITICAL') & isequal(m.row_colors(1, :), RED));
assert(strcmp(m.rows{1, 3}, 'n/a PSI | n/a bar'));          % no reading, still a coherent row
assert(has(m.rows{1, 7}, 'No usable sensor data'));
world('fail') = {};

% ============================ banner ============================
m = dashboard_update([], e, info0);
assert(has(m.banner_lines{1}, 'READ-ONLY') & has(m.banner_lines{1}, 'http://test:8069'));
assert(has(m.banner_lines{1}, 'cycle 1') & has(m.banner_lines{1}, 'limits fixed'));
assert(isequal(m.banner_color, [0.20 0.38 0.60]));
info_post = info0;  info_post.send_http = true;  info_post.iteration = 7;
m = dashboard_update([], e, info_post);
assert(has(m.banner_lines{1}, 'POSTING ON') & has(m.banner_lines{1}, 'cycle 7'));
assert(isequal(m.banner_color, [0.75 0.15 0.15]));
% reload status
info_r = info0;  info_r.limits_reloading = true;  info_r.limits_age_s = 12.4;
m = dashboard_update([], e, info_r);
assert(has(m.banner_lines{1}, 'reloaded 12 s ago (every 30 s)'));
info_r.limits_fail_count = 2;
m = dashboard_update([], e, info_r);
assert(has(m.banner_lines{1}, 'LAST 2 RELOAD(S) FAILED'));
% a limit change is announced, then fades after 30 cycles
info_c = info0;  info_c.iteration = 10;
info_c.limit_changes = {'LIMIT CHANGE feed_pipeline: design_pressure 35 -> 37 PSI'};
m = dashboard_update([], e, info_c);
assert(has(m.banner_lines{2}, 'design_pressure 35 -> 37 PSI'));
info_n = info0;  info_n.iteration = 39;  info_n.limit_changes = {};
m2 = dashboard_update(m, e, info_n);
assert(has(m2.banner_lines{2}, 'design_pressure'));         % 29 cycles later: still shown
info_n.iteration = 40;
m2 = dashboard_update(m, e, info_n);
assert(isempty(m2.banner_lines{2}));                         % 30 cycles later: gone

% ============================ the drawn band matches the REAL checks ============================
% at_risk_bands is display-only; this guards against it drifting from the checks.
for mf = [0.9 0.8]
    o = struct('margin_fraction', mf);
    lim = struct('pressure_bar', 5, 'temperature_c', 150, 'flow_kg_s', 10);
    b = at_risk_bands(lim, mf);
    pp = struct('pipe_diameter', 0.1, 'pipe_length', 10, 'fluid_density', 1000, 'fluid_viscosity', 1e-3);
    mkr = @(P, T, F) struct('location', 'x', 'pressure', P, 'temperature', T, 'flow_rate', F, 'timestamp', 0);

    assert(strcmp(check_pressure(mkr(b.pressure_bar - 0.001, 0, 0), 5, [], o).status, 'SAFE'));
    assert(strcmp(check_pressure(mkr(b.pressure_bar + 0.001, 0, 0), 5, [], o).status, 'AT_RISK'));
    assert(strcmp(check_temperature(mkr(0, b.temperature_c - 0.01, 0), 150, [], o).status, 'SAFE'));
    assert(strcmp(check_temperature(mkr(0, b.temperature_c + 0.01, 0), 150, [], o).status, 'AT_RISK'));
    assert(strcmp(check_flow(mkr(0, 0, b.flow_kg_s - 0.001), 10, pp, [], o).status, 'SAFE'));
    assert(strcmp(check_flow(mkr(0, 0, b.flow_kg_s + 0.001), 10, pp, [], o).status, 'AT_RISK'));
end

% ============================ diff_limits ============================
old_s = struct('feed_pipeline', struct('design_pressure', 35, 'design_temperature', 100, ...
               'flow_limit', 0.18, 'pipe_length', 25, 'diameter', 6), ...
               'column_top', struct('design_pressure', 48, 'design_temperature', 146, ...
               'flow_limit', 0.19, 'pipe_length', 8, 'diameter', 6));
new_s = old_s;
assert(isempty(diff_limits(old_s, new_s)));                          % nothing changed
assert(isempty(diff_limits([], new_s)));                             % first load is not a change
new_s.feed_pipeline.design_pressure = 37;
ch = diff_limits(old_s, new_s);
assert(numel(ch) == 1 & strcmp(ch{1}, 'LIMIT CHANGE feed_pipeline: design_pressure 35 -> 37 PSI'));
new_s.column_top.design_temperature = 150;
new_s.column_top.flow_limit = 0.2;
ch = diff_limits(old_s, new_s);
assert(numel(ch) == 3 & has(strjoin(ch, ' '), 'design_temperature 146 -> 150 F'));
assert(has(strjoin(ch, ' '), 'flow_limit 0.19 -> 0.2 kg/s'));
new_s.extra_location = new_s.feed_pipeline;                          % a new location is ignored
assert(numel(diff_limits(old_s, new_s)) == 3);

% ============================ loop hooks ============================
cnt = containers.Map();  cnt('n') = 0;
seen = containers.Map();

% on_cycle gets entries and info every cycle
s1 = settings;  s1.max_iterations = 3;
s1.on_cycle = @(en, inf_) record_cycle(seen, en, inf_);
[hist, ~] = run_safety_loop(s1, cfg);
assert(numel(hist) == 3 & seen.Count == 3);
i2 = seen('2');
assert(i2.n_entries == 5 & i2.iteration == 2 & i2.send_http == false & i2.reloading == false);

% an error inside the display hook cannot stop the loop
s2 = settings;  s2.max_iterations = 3;
s2.on_cycle = @(en, inf_) error('drawing blew up');
[hist, ~] = run_safety_loop(s2, cfg);
assert(numel(hist) == 3);

% stop_fn ends the loop (this is how closing the window stops it)
s3 = settings;  s3.max_iterations = 50;
s3.on_cycle = @(en, inf_) bump(cnt);
s3.stop_fn  = @() cnt('n') >= 2;
[hist, ~] = run_safety_loop(s3, cfg);
assert(numel(hist) == 2);

% ============================ periodic limits reload ============================
d_ = default_settings();
assert(d_.limits_reload_interval_s == 30);

% reload picks up a changed limit MID-SESSION, with no restart
spec_of = @(psi) struct('design_pressure', psi, 'design_temperature', 100, 'flow_limit', 0.2, ...
                        'pipe_length', 5, 'diameter', 6);
calls = containers.Map();  calls('n') = 0;
seen = containers.Map();
s4 = settings;  s4.max_iterations = 3;  s4.limits_reload_interval_s = 0;   % reload every cycle
s4.limits_specs = struct_for(locs, spec_of(35));
s4.limits_reload_fn = @() fake_reload(calls, locs, 'change');
s4.on_cycle = @(en, inf_) record_cycle(seen, en, inf_);
[hist, ~] = run_safety_loop(s4, cfg);
assert(calls('n') == 3);
c1 = hist{1};  c2 = hist{2};
% call 1 returns the same limits/specs -> nothing announced
assert(isempty(seen('1').changes));
assert(strcmp(c1(1).odoo_status, 'safe'));
% call 2: feed_pipeline's pressure limit drops to 1 bar (30 PSI = 2.07 bar) -> now CRITICAL
assert(c2(1).limits.pressure_bar == 1);
assert(strcmp(c2(1).odoo_status, 'critical'));
assert(strcmp(c2(2).odoo_status, 'safe'));                           % other locations untouched
assert(numel(seen('2').changes) == 1 & has(seen('2').changes{1}, 'feed_pipeline: design_pressure 35 -> 37 PSI'));
assert(seen('2').reloading == true);
% the new geometry from the reload reaches check_flow's inputs without error
assert(isempty(c2(1).error));

% a failed reload keeps the previous limits, is counted, and recovers
calls = containers.Map();  calls('n') = 0;  seen = containers.Map();
s5 = settings;  s5.max_iterations = 4;  s5.limits_reload_interval_s = 0;
s5.limits_specs = struct_for(locs, spec_of(35));
s5.limits_reload_fn = @() fake_reload(calls, locs, 'fail_on_2');
s5.on_cycle = @(en, inf_) record_cycle(seen, en, inf_);
[hist, ~] = run_safety_loop(s5, cfg);
assert(numel(hist) == 4);                                            % the loop kept running
assert(seen('1').fails == 0 & seen('2').fails == 1 & seen('3').fails == 2 & seen('4').fails == 0);
assert(hist{2}(1).limits.pressure_bar == 10);                        % previous limits kept

% with a long interval the reload function is not called every cycle
calls = containers.Map();  calls('n') = 0;
s6 = settings;  s6.max_iterations = 3;  s6.limits_reload_interval_s = 1e6;
s6.limits_specs = struct_for(locs, spec_of(35));
s6.limits_reload_fn = @() fake_reload(calls, locs, 'change');
[~, ~] = run_safety_loop(s6, cfg);
assert(calls('n') == 0);

disp('All dashboard / limits-reload / loop-hook tests passed.');

% ---------------- local helpers ----------------
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

function s = struct_for(locs, value)
    for k = 1:numel(locs)
        s.(locs{k}) = value;
    end
end

function record_cycle(seen, en, inf_)
    seen(sprintf('%d', inf_.iteration)) = struct('n_entries', numel(en), ...
        'iteration', inf_.iteration, 'send_http', inf_.send_http, ...
        'reloading', inf_.limits_reloading, 'changes', {inf_.limit_changes}, ...
        'fails', inf_.limits_fail_count);
end

function bump(cnt)
    cnt('n') = cnt('n') + 1;
end

function [limits, geo, specs] = fake_reload(calls, locs, mode)
% Call 1: same limits as the starting ones. Call 2 ('change'): feed_pipeline's limit
% changes in Odoo (35 -> 37 PSI) and the derived limit drops to 1 bar. Call 2
% ('fail_on_2') throws; later calls succeed with unchanged limits.
    calls('n') = calls('n') + 1;
    n = calls('n');
    if strcmp(mode, 'fail_on_2')
        if n == 2 | n == 3
            error('fake:down', 'Odoo unreachable');
        end
    end
    base = struct('pressure_bar', 10, 'temperature_c', 150, 'flow_kg_s', 10);
    spec = struct('design_pressure', 35, 'design_temperature', 100, 'flow_limit', 0.2, ...
                  'pipe_length', 5, 'diameter', 6);
    for k = 1:numel(locs)
        limits.(locs{k}) = base;
        geo.(locs{k}) = struct('pipe_diameter', 0.1524, 'pipe_length', 5);
        specs.(locs{k}) = spec;
    end
    if strcmp(mode, 'change')
        if n >= 2
            limits.feed_pipeline.pressure_bar = 1;
            specs.feed_pipeline.design_pressure = 37;
        end
    end
end

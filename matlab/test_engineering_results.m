% Headless test script for the engineering-results payload and its optional POST.
% No network: the sender is a recorder. Run: test_engineering_results

cfg = struct('odoo_base_url', 'http://test:8069', 'rosbridge_url', 'ws://test:9090');
locs = {'feed_pipeline', 'column_bottom', 'column_top', 'bottoms_output', 'distillate_output'};
has = @(s, sub) ~isempty(strfind(s, sub));

limits = struct('pressure_bar', 10, 'temperature_c', 150, 'flow_kg_s', 10);
pp = struct('pipe_diameter', 0.1524, 'pipe_length', 5, 'fluid_density', 1000, 'fluid_viscosity', 1e-3);
mk = @(P, T, F, t) struct('location', 'feed_pipeline', 'pressure', P, 'temperature', T, ...
                          'flow_rate', F, 'timestamp', t);

FIELDS6 = {'velocity'; 'reynolds_number'; 'friction_factor'; 'pressure_drop'; ...
          'temperature_rate'; 'pressure_rate'};

% ============================ the payload ============================
r = combine_checks(mk(3, 80, 0.5, 0), limits, pp);
p = to_engineering_payload(r);
assert(isequal(fieldnames(p), FIELDS6));
f = r.checks.flow;                      % the hydraulics are the flow check's own numbers
assert(p.velocity == f.velocity & p.reynolds_number == f.reynolds_number);
assert(p.friction_factor == f.friction_factor & p.pressure_drop == f.pressure_drop);
assert(isfinite(p.velocity) & isfinite(p.reynolds_number) & p.velocity > 0 & p.reynolds_number > 0);

% independent recomputation (laminar/turbulent formulas from first principles)
A = pi * 0.1524^2 / 4;  v = 0.5 / 1000 / A;  Re = 1000 * v * 0.1524 / 1e-3;
assert(abs(p.velocity - v) < 1e-12 & abs(p.reynolds_number - Re) < 1e-6 * Re);

% no previous_reading -> both rates NaN (nothing to compute a rate from)
assert(isnan(p.temperature_rate) & isnan(p.pressure_rate));

% ---- rates: sourced from check_pressure/check_temperature's own rate_*_per_s, not recomputed ----
r = combine_checks(mk(3.4, 84, 0.5, 1), limits, pp, mk(3.0, 80, 0.5, 0));
p = to_engineering_payload(r);
assert(p.pressure_rate == r.checks.pressure.rate_Pa_per_s);       % same value the check returned
assert(p.temperature_rate == r.checks.temperature.rate_K_per_s);
assert(abs(p.pressure_rate - 0.4e5) < 1e-6);                      % (3.4-3.0) bar / 1 s, in Pa/s
assert(abs(p.temperature_rate - 4) < 1e-9);                       % (84-80) C / 1 s, in K/s (deg C step = K step)
% units need no conversion: Odoo's engineering_results wants exactly Pa/s and K/s
assert(strcmp(class(p.pressure_rate), 'double') & strcmp(class(p.temperature_rate), 'double'));

% a fast FALL is a real (negative) rate here, unlike the AT_RISK trip which is one-sided
r = combine_checks(mk(3.0, 80, 0.5, 1), limits, pp, mk(3.4, 84, 0.5, 0));
p = to_engineering_payload(r);
assert(p.pressure_rate < 0 & p.temperature_rate < 0);
assert(strcmp(r.status, 'SAFE'));                                 % the fall itself never trips AT_RISK

% Delta_t = 0 (skipped rate check) -> NaN rate, not a crash
r = combine_checks(mk(3.4, 84, 0.5, 5), limits, pp, mk(3.0, 80, 0.5, 5));
p = to_engineering_payload(r);
assert(isnan(p.pressure_rate) & isnan(p.temperature_rate));

% it carries the hydraulics even when the location is CRITICAL (they are informational)
r = combine_checks(mk(12, 80, 0.5, 0), limits, pp);
assert(strcmp(r.status, 'CRITICAL'));
assert(isfinite(to_engineering_payload(r).reynolds_number));

% bad pipe parameters -> hydraulics NaN, no error (they would go out as JSON null)
r = combine_checks(mk(3, 80, 0.5, 0), limits, []);
p = to_engineering_payload(r);
assert(all(structfun(@isnan, p)));

% it must NOT look like a safety verdict: post_to_odoo decides how to encode by the 'status' field
assert(~isfield(to_engineering_payload(combine_checks(mk(3, 80, 0.5, 0), limits, pp)), 'status'));

% ============================ URL ============================
assert(strcmp(odoo_url(cfg, 'engineering_results', 'column_top'), ...
              'http://test:8069/api/engineering_results/column_top'));

% ============================ through poll_cycle ============================
rec = containers.Map();
settings = default_settings();
settings.fetch_fn = @(loc) struct('location', loc, 'pressure_psi', 30, 'temperature_F', 100, 'flow_gpm', 2);
settings.now_fn = @() 1000;
settings.send_fn = @(u, p_) record_send(rec, u, p_);
settings.verbose = false;
for k = 1:numel(locs)
    settings.limits.(locs{k}) = limits;
end

% OFF by default: exactly one POST per location (the safety verdict)
assert(settings.send_engineering == false);
[e, ~] = poll_cycle(cfg, settings);
assert(rec.Count == 5 & ~any([e.eng_sent]));
assert(all(cellfun(@(k) has(rec(k).url, '/api/safety_status/'), rec.keys())));

% ON: safety verdict first, then engineering results, for every location
rec.remove(rec.keys());
settings.send_engineering = true;
[e, ~] = poll_cycle(cfg, settings);
assert(rec.Count == 10);
assert(all([e.sent]) & all([e.eng_sent]));
for k = 1:5
    a = rec(sprintf('%d', 2 * k - 1));   % 1st, 3rd, 5th ... = safety
    b = rec(sprintf('%d', 2 * k));       % 2nd, 4th ...     = engineering
    assert(has(a.url, ['/api/safety_status/' locs{k}]) & isfield(a.payload, 'status'));
    assert(has(b.url, ['/api/engineering_results/' locs{k}]) & ~isfield(b.payload, 'status'));
    assert(isequal(fieldnames(b.payload), FIELDS6));
    % hydraulics are finite (a real reading with pipe_geometry); rates are NaN on
    % cycle 1 of this test (no previous_reading yet) - both are expected, not a bug
    assert(isfinite(b.payload.velocity) & isfinite(b.payload.reynolds_number));
    assert(isnan(b.payload.temperature_rate) & isnan(b.payload.pressure_rate));
end

% a CRITICAL location still sends its engineering results, after the verdict
rec.remove(rec.keys());
w = settings;  w.locations = {'feed_pipeline'};
w.fetch_fn = @(loc) struct('location', loc, 'pressure_psi', 200, 'temperature_F', 100, 'flow_gpm', 2);
[e, ~] = poll_cycle(cfg, w);
assert(strcmp(e(1).odoo_status, 'critical') & e(1).sent & e(1).eng_sent & rec.Count == 2);

% ---- a failing engineering POST can never blank or block the safety verdict ----
% (a) the sender reports failure (like an HTTP error) for the engineering URL only
w = settings;  w.locations = {'feed_pipeline'};
w.send_fn = @(u, p_) selective_send(u, p_, 'returns_false');
[e, ~] = poll_cycle(cfg, w);
assert(e(1).sent & strcmp(e(1).odoo_status, 'safe') & isempty(e(1).error));
assert(~e(1).eng_sent & has(e(1).eng_msg, 'engineering endpoint refused'));
% (b) the sender THROWS for the engineering URL only (like a dropped connection)
w.send_fn = @(u, p_) selective_send(u, p_, 'throws');
[e, ~] = poll_cycle(cfg, w);
assert(e(1).sent & strcmp(e(1).odoo_status, 'safe') & isempty(e(1).error));   % verdict intact
assert(~e(1).eng_sent & has(e(1).eng_msg, 'engineering send failed'));

% locations that were skipped (fetch failure) send nothing
rec.remove(rec.keys());
w = settings;  w.locations = {'feed_pipeline'};
w.fetch_fn = @(loc) error('sim:down', 'sensor down');
[e, ~] = poll_cycle(cfg, w);
assert(e(1).skipped & rec.Count == 0 & ~e(1).eng_sent);

disp('All engineering-results tests passed.');

% ---------------- local helpers ----------------
function [ok, msg] = record_send(rec, url, payload)
    rec(sprintf('%d', rec.Count + 1)) = struct('url', url, 'payload', payload);
    ok  = true;
    msg = 'recorded';
end

function [ok, msg] = selective_send(url, ~, mode)
% Fine for the safety endpoint; misbehaves only for engineering_results.
    ok = true;  msg = 'posted';
    if ~isempty(strfind(url, 'engineering_results'))
        if strcmp(mode, 'throws')
            error('sim:refused', 'connection refused');
        else
            ok = false;  msg = 'engineering endpoint refused';
        end
    end
end

% End-to-end test of the REAL MATLAB sender against the local mock Odoo.
% Needs NO network beyond your own Mac, so it works whatever Wi-Fi you are on.
%
%   1. In a terminal:   python3 ~/matlab_mock_odoo/mock_odoo.py --tuned
%      (fresh start, default port 8069, and --tuned so idle readings are SAFE)
%   2. In MATLAB:       test_against_mock
%
% It runs, in order:
%   1  POST for feed_pipeline only, then all five      (real webwrite + JSON-RPC envelope)
%   3  CRITICAL latches, SAFE/WARNING are refused, reset un-latches
%      then a real simulated spike end to end
%   4  engineering results POST (velocity, Reynolds, friction factor, pressure drop)
%   2  the mock is STOPPED mid-run; the loop must skip/fail safe, not crash
% Step 2 goes last because it shuts the mock down. Restart the mock to run again.
% Takes about a minute. Any failed assert stops the script with the line number.

base = 'http://127.0.0.1:8069';   % 127.0.0.1, not localhost: the mock listens on IPv4 only
cfg  = struct('odoo_base_url', base, 'rosbridge_url', 'ws://localhost:9090');
opt  = weboptions('Timeout', 5, 'ContentType', 'json');
has  = @(s, sub) ~isempty(strfind(s, sub));
mstate = @() webread([base '/mock/state'], opt);

% ---- preconditions: the mock is up and tuned ----
try
    webread([base '/mock/state'], opt);
catch
    error('The mock is not running. In a terminal: python3 ~/matlab_mock_odoo/mock_odoo.py --tuned');
end
spec = webread([base '/api/equipment/column_bottom'], opt);
assert(spec.design_temperature == 190, ...
       'Restart the mock WITH --tuned (its temperature limits keep idle SAFE).');
webread([base '/mock/reset/all'], opt);

settings = default_settings();
[settings.limits, settings.pipe_geometry_by_location] = load_limits_from_odoo(settings.locations, cfg);
settings.fetch_fn = @(loc) fetch_live_reading(loc, cfg, 5);
settings.send_http = true;              % REAL webwrite, but only to your own Mac
settings.verbose = false;
locs = settings.locations;
count = @(s, l) s.(l).posts_received;

% ============================ STEP 1: feed_pipeline only, then all five ============================
fprintf('STEP 1: POST for feed_pipeline only\n');
before = mstate();
s1 = settings;  s1.locations = {'feed_pipeline'};
[e, ~] = poll_cycle(cfg, s1);
assert(numel(e) == 1);
assert(e(1).sent, 'POST failed: %s', e(1).send_msg);
assert(strcmp(e(1).send_msg, 'posted'));                             % response was {"ok": true}
assert(strcmp(e(1).odoo_status, 'safe'), 'idle should be safe, got: %s', e(1).reason);
after = mstate();
assert(count(after, 'feed_pipeline') == count(before, 'feed_pipeline') + 1);
assert(strcmp(after.feed_pipeline.last_post.status, 'safe'));
assert(strcmp(after.feed_pipeline.last_post.reason, e(1).reason));   % the reason text arrived intact
for k = 2:5                                                          % the other four got nothing
    assert(count(after, locs{k}) == count(before, locs{k}));
end
fprintf('  PASS  feed_pipeline posted once, status safe, reason arrived intact, others untouched\n');

fprintf('STEP 1: expand to all five\n');
before = mstate();
[e, ~] = poll_cycle(cfg, settings);
assert(numel(e) == 5 & all([e.sent]) & all(strcmp({e.send_msg}, 'posted')));
assert(all(strcmp({e.odoo_status}, 'safe')), 'expected all safe at idle');
after = mstate();
for k = 1:5
    assert(count(after, locs{k}) == count(before, locs{k}) + 1);
    assert(~after.(locs{k}).latched);
end
fprintf('  PASS  all five posted once each, all safe, none latched\n');

% ============================ STEP 3: latch / reset ============================
fprintf('STEP 3: CRITICAL latches\n');
s3 = settings;  s3.locations = {'feed_pipeline'};
bad  = @(loc) struct('location', loc, 'temperature_F', 90, 'pressure_psi', 200, 'flow_gpm', 2);
good = @(loc) struct('location', loc, 'temperature_F', 90, 'pressure_psi', 30,  'flow_gpm', 2);
mid  = @(loc) struct('location', loc, 'temperature_F', 90, 'pressure_psi', 33,  'flow_gpm', 2);   % AT_RISK band

s3.fetch_fn = bad;
[e, ~] = poll_cycle(cfg, s3);
assert(strcmp(e(1).odoo_status, 'critical') & e(1).sent & e(1).shutdown_signal == 1);
st = mstate();
assert(st.feed_pipeline.latched & strcmp(st.feed_pipeline.valve, 'closed'));
vc = webread([base '/api/valve_commands/feed_pipeline'], opt);
assert(strcmp(vc.valve_command, 'closed'));
fprintf('  PASS  CRITICAL sent, mock latched it, valve closed\n');

fprintf('STEP 3: later SAFE and WARNING are rejected\n');
s3.fetch_fn = good;
[e, ~] = poll_cycle(cfg, s3);
assert(strcmp(e(1).odoo_status, 'safe') & ~e(1).sent);              % MATLAB decided safe, Odoo refused
assert(has(e(1).send_msg, 'latched CRITICAL'), 'message was: %s', e(1).send_msg);
s3.fetch_fn = mid;
[e, ~] = poll_cycle(cfg, s3);
assert(strcmp(e(1).odoo_status, 'warning') & ~e(1).sent & has(e(1).send_msg, 'latched CRITICAL'));
assert(strcmp(mstate().feed_pipeline.status, 'critical'));          % Odoo's status did not change
fprintf('  PASS  SAFE and WARNING refused ("%s...")\n', e(1).send_msg(1:38));

fprintf('STEP 3: reset un-latches\n');
webread([base '/mock/reset/feed_pipeline'], opt);
assert(~mstate().feed_pipeline.latched);
s3.fetch_fn = good;
[e, ~] = poll_cycle(cfg, s3);
assert(e(1).sent & strcmp(e(1).odoo_status, 'safe') & strcmp(e(1).send_msg, 'posted'));
assert(strcmp(webread([base '/api/valve_commands/feed_pipeline'], opt).valve_command, 'open'));
fprintf('  PASS  after reset SAFE is accepted again, valve open\n');

fprintf('STEP 3: a real simulated spike, end to end (takes up to ~25 s)\n');
webread([base '/mock/reset/all'], opt);
webread([base '/mock/spike?hold=12'], opt);
state = [];  hit = false;
for cyc = 1:30
    [e, state] = poll_cycle(cfg, settings, state);
    crit = strcmp({e.odoo_status}, 'critical') & [e.sent];
    if any(crit)
        hit = true;
        break
    end
    pause(1);
end
assert(hit, 'no location reached CRITICAL within 30 s of the spike');
first = locs{find(crit, 1)};
assert(mstate().(first).latched);
fprintf('  PASS  spike -> %s went CRITICAL after %d cycles, mock latched it\n', first, cyc);
webread([base '/mock/reset/all'], opt);
pause(14);                                                           % let the spike finish

% ============================ STEP 4: engineering results ============================
fprintf('STEP 4: engineering results\n');
s4 = settings;  s4.locations = {'feed_pipeline'};  s4.send_engineering = true;
before = mstate();
[e, ~] = poll_cycle(cfg, s4);
assert(e(1).sent & e(1).eng_sent, 'engineering POST failed: %s', e(1).eng_msg);
assert(strcmp(e(1).eng_msg, 'posted'));
after = mstate();
assert(after.feed_pipeline.eng_posts_received == before.feed_pipeline.eng_posts_received + 1);
assert(count(after, 'feed_pipeline') == count(before, 'feed_pipeline') + 1);   % the verdict was sent too
got = after.feed_pipeline.last_eng;
% compare with the hydraulics computed locally from the same reading
fl = settings.pipe_geometry_by_location.feed_pipeline;
fl.fluid_density = 1000;  fl.fluid_viscosity = 1e-3;
ref = check_flow(e(1).reading, settings.limits.feed_pipeline.flow_kg_s, fl);
assert(abs(got.velocity - ref.velocity) < 1e-9 * abs(ref.velocity));
assert(abs(got.reynolds_number - ref.reynolds_number) < 1e-9 * ref.reynolds_number);
assert(abs(got.friction_factor - ref.friction_factor) < 1e-9);
assert(abs(got.pressure_drop - ref.pressure_drop) < 1e-9 * max(1, abs(ref.pressure_drop)));
fprintf('  PASS  mock received v=%.3f m/s, Re=%.0f, f=%.4f, dP=%.1f Pa (match local calc)\n', ...
        got.velocity, got.reynolds_number, got.friction_factor, got.pressure_drop);

% ============================ STEP 2: server stops mid-run ============================
fprintf('STEP 2: stopping the mock mid-run (Odoo going away)\n');
webread([base '/mock/shutdown'], opt);
pause(1);
state = [];
for cyc = 1:3
    tic;
    [e, state] = poll_cycle(cfg, settings, state);                    % must not throw
    took = toc;
    assert(numel(e) == 5);
    assert(all(~[e.sent]), 'nothing can be delivered with the server down');
    if cyc < 3
        assert(all([e.skipped]) & all(cellfun(@(s) has(s, 'fetch failed'), {e.error})));
        fprintf('  cycle %d: all 5 skipped ("fetch failed"), no crash, %.1f s\n', cyc, took);
    else
        % third consecutive failure: treated as bad data -> fail safe locally
        assert(all(strcmp({e.status}, 'CRITICAL')) & all([e.shutdown_signal] == 1));
        assert(all(cellfun(@(s) has(s, 'No usable sensor data'), {e.reason})));
        assert(all(~cellfun(@isempty, {e.send_msg})));               % the delivery failure is recorded
        fprintf('  cycle 3: all 5 fail safe to CRITICAL/SHUTDOWN locally, delivery failure recorded\n');
    end
end
% the whole loop keeps running too
settings.max_iterations = 2;  settings.poll_interval_s = 0;
[hist, ~] = run_safety_loop(settings, cfg);
assert(numel(hist) == 2);
fprintf('  PASS  run_safety_loop survived 2 more cycles with the server down\n');

disp('All mock-integration tests passed.');

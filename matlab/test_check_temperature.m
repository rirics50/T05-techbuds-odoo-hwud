% Headless test script for check_temperature. Run: test_check_temperature
% Errors out (via assert) on first failure, so it also works from
% `matlab -batch test_check_temperature`.

limit = 150;   % deg C = 423.15 K
% Margin is 0.9 of the limit in deg C: 0.9 * 150 = 135 C (compared in K as 408.15 K).

% Helper: build a reading struct using the contract field names.
mk = @(T, t) struct('location', 'column_bottom', 'temperature', T, ...
                    'valve_position', 60, 'timestamp', t);

% ---- Tiers ----

% Well below margin -> SAFE / CONTINUE, valve held at 60
r = check_temperature(mk(80, 0), limit);
assert(strcmp(r.status, 'SAFE') & strcmp(r.action, 'CONTINUE'));
assert(r.valve_command == 60);

% Inside margin band -> AT_RISK / ADJUST_VALVE, partial valve
r = check_temperature(mk(140, 0), limit);
assert(strcmp(r.status, 'AT_RISK') & strcmp(r.action, 'ADJUST_VALVE'));
assert(r.valve_command > 0 & r.valve_command < 100);

% Just under margin stays SAFE
r = check_temperature(mk(134, 0), limit);
assert(strcmp(r.status, 'SAFE'));

% Above limit -> CRITICAL / SHUTDOWN, valve closed
r = check_temperature(mk(160, 0), limit);
assert(strcmp(r.status, 'CRITICAL') & strcmp(r.action, 'SHUTDOWN'));
assert(r.valve_command == 0);

% Exactly at limit -> CRITICAL (boundary)
r = check_temperature(mk(150, 0), limit);
assert(strcmp(r.status, 'CRITICAL') & r.valve_command == 0);

% NaN sensor value -> fail safe
r = check_temperature(mk(NaN, 0), limit);
assert(strcmp(r.status, 'CRITICAL') & strcmp(r.action, 'SHUTDOWN') & r.valve_command == 0);

% Location passes through untouched
assert(strcmp(r.location, 'column_bottom'));

% Output has exactly the five contract fields
assert(isequal(sort(fieldnames(r)), sort({'location';'status';'action';'valve_command';'reason'})));

% ---- Rate of change (placeholder 3 K/s) ----

% 80 -> 84 C in 1 s = 4 K/s > 3 placeholder -> AT_RISK though far below limit
r = check_temperature(mk(84, 1), limit, mk(80, 0));
assert(strcmp(r.status, 'AT_RISK') & strcmp(r.action, 'ADJUST_VALVE'));
assert(~isempty(strfind(r.reason, 'dT/dt')));

% Worst-case sensor noise (+/-1 F -> consecutive samples 2 F = 1.11 K apart,
% 1.11 K/s at a 1 s poll) must NOT trip: this is why the threshold is 3
r = check_temperature(mk(81.11, 1), limit, mk(80, 0));
assert(strcmp(r.status, 'SAFE'));
% ... even if timing jitter halves the interval (2.22 K/s, still under 3)
r = check_temperature(mk(81.11, 0.5), limit, mk(80, 0));
assert(strcmp(r.status, 'SAFE'));

% Slow rise: 0.1 K/s -> SAFE
r = check_temperature(mk(80.1, 1), limit, mk(80, 0));
assert(strcmp(r.status, 'SAFE'));

% Fast FALL must not trip the rate check
r = check_temperature(mk(80, 1), limit, mk(84, 0));
assert(strcmp(r.status, 'SAFE'));

% Rate never downgrades CRITICAL
r = check_temperature(mk(160, 1), limit, mk(155, 0));
assert(strcmp(r.status, 'CRITICAL') & r.valve_command == 0);

% Rate limit is an argument: same jump, looser threshold -> SAFE
r = check_temperature(mk(84, 1), limit, mk(80, 0), struct('temp_rate_limit_K_per_s', 5));
assert(strcmp(r.status, 'SAFE'));

% margin_fraction comes from the shared defaults and is overridable:
% 140 C is AT_RISK at 0.9 (135 C), but SAFE at 0.99 (148.5 C)
r = check_temperature(mk(140, 0), limit, [], struct('margin_fraction', 0.99));
assert(strcmp(r.status, 'SAFE'));

% ---- No previous reading: must not crash ----
r = check_temperature(mk(80, 1), limit, []);
assert(strcmp(r.status, 'SAFE'));
r = check_temperature(mk(80, 1), limit);
assert(strcmp(r.status, 'SAFE'));

% ---- Delta_t = 0 (duplicate timestamp): no divide-by-zero, rate skipped ----
r = check_temperature(mk(90, 5), limit, mk(80, 5));
assert(strcmp(r.status, 'SAFE'));
assert(~isempty(strfind(r.reason, 'rate check skipped')));

% ---- Delta_t < 0 (out-of-order): rate skipped ----
r = check_temperature(mk(90, 4), limit, mk(80, 5));
assert(strcmp(r.status, 'SAFE'));
assert(~isempty(strfind(r.reason, 'rate check skipped')));

% ---- Previous reading with NaN temperature: rate skipped, no crash ----
r = check_temperature(mk(80, 1), limit, mk(NaN, 0));
assert(strcmp(r.status, 'SAFE'));

disp('All check_temperature tests passed.');

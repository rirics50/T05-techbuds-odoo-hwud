% Headless test script for check_pressure. Run: test_check_pressure
% Errors out (via assert) on first failure, so it also works from
% `matlab -batch test_check_pressure`.

limit = 5.0;   % bar  (AT_RISK band starts at 0.9 * 5 = 4.5 bar)

% Helper: build a reading struct using the contract field names.
mk = @(p, t) struct('location', 'column_bottom', 'pressure', p, ...
                    'valve_position', 60, 'timestamp', t);

% ---- Original cases (must still pass) ----

% Below margin -> SAFE / CONTINUE, valve held at 60
r = check_pressure(mk(3.2, 0), limit);
assert(strcmp(r.status, 'SAFE') & strcmp(r.action, 'CONTINUE'));
assert(r.valve_command == 60);

% Above limit -> CRITICAL / SHUTDOWN, valve closed
r = check_pressure(mk(6.1, 0), limit);
assert(strcmp(r.status, 'CRITICAL') & strcmp(r.action, 'SHUTDOWN'));
assert(r.valve_command == 0);

% Exactly at limit -> CRITICAL (boundary)
r = check_pressure(mk(5.0, 0), limit);
assert(strcmp(r.status, 'CRITICAL') & r.valve_command == 0);

% NaN sensor value -> fail safe
r = check_pressure(mk(NaN, 0), limit);
assert(strcmp(r.status, 'CRITICAL') & r.valve_command == 0);

% Location passes through untouched
assert(strcmp(r.location, 'column_bottom'));

% ---- AT_RISK band ----

% Between 4.5 and 5.0 bar -> AT_RISK / ADJUST_VALVE, partial valve
r = check_pressure(mk(4.7, 0), limit);
assert(strcmp(r.status, 'AT_RISK') & strcmp(r.action, 'ADJUST_VALVE'));
assert(r.valve_command > 0 & r.valve_command < 100);

% Just under the margin stays SAFE
r = check_pressure(mk(4.4, 0), limit);
assert(strcmp(r.status, 'SAFE'));

% ---- Rate of change ----

% 3.0 -> 3.2 bar in 1 s = 20000 Pa/s > 5000 placeholder -> AT_RISK though far below limit
r = check_pressure(mk(3.2, 1), limit, mk(3.0, 0));
assert(strcmp(r.status, 'AT_RISK') & strcmp(r.action, 'ADJUST_VALVE'));
assert(~isempty(strfind(r.reason, 'dP/dt')));

% Slow rise: 100 Pa/s -> SAFE
r = check_pressure(mk(3.001, 1), limit, mk(3.0, 0));
assert(strcmp(r.status, 'SAFE'));

% Fast FALL must not trip the rate check
r = check_pressure(mk(3.0, 1), limit, mk(3.2, 0));
assert(strcmp(r.status, 'SAFE'));

% Rate never downgrades CRITICAL
r = check_pressure(mk(6.1, 1), limit, mk(6.0, 0));
assert(strcmp(r.status, 'CRITICAL') & r.valve_command == 0);

% Rate limit is an argument: same jump, looser threshold -> SAFE
r = check_pressure(mk(3.2, 1), limit, mk(3.0, 0), struct('rate_limit_Pa_per_s', 50000));
assert(strcmp(r.status, 'SAFE'));

% ---- No previous reading: must not crash ----
r = check_pressure(mk(3.2, 1), limit, []);
assert(strcmp(r.status, 'SAFE'));

% ---- Delta_t = 0 (duplicate timestamp): no divide-by-zero, rate skipped ----
r = check_pressure(mk(3.2, 5), limit, mk(3.0, 5));
assert(strcmp(r.status, 'SAFE'));
assert(~isempty(strfind(r.reason, 'rate check skipped')));

% ---- Delta_t < 0 (out-of-order): rate skipped ----
r = check_pressure(mk(3.2, 4), limit, mk(3.0, 5));
assert(strcmp(r.status, 'SAFE'));
assert(~isempty(strfind(r.reason, 'rate check skipped')));

% ---- Previous reading with NaN pressure: rate skipped, no crash ----
r = check_pressure(mk(3.2, 1), limit, mk(NaN, 0));
assert(strcmp(r.status, 'SAFE'));

disp('All check_pressure tests passed.');

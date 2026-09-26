% Headless test script for check_flow. Run: test_check_flow
% Errors out (via assert) on first failure, so it also works from
% `matlab -batch test_check_flow`.

limit = 10;   % kg/s  (AT_RISK band starts at 0.9 * 10 = 9 kg/s)

% Water in a 10 cm, 10 m pipe. All SI.
pp = struct('pipe_diameter', 0.1, 'pipe_length', 10, ...
            'fluid_density', 1000, 'fluid_viscosity', 1e-3);

mk = @(m, t) struct('location', 'feed_pipeline', 'flow_rate', m, ...
                    'valve_position', 60, 'timestamp', t);

% ---- Tiers ----

r = check_flow(mk(5, 0), limit, pp);
assert(strcmp(r.status, 'SAFE') & strcmp(r.action, 'CONTINUE'));
assert(r.valve_command == 60);

r = check_flow(mk(9.5, 0), limit, pp);
assert(strcmp(r.status, 'AT_RISK') & strcmp(r.action, 'ADJUST_VALVE'));
assert(r.valve_command > 0 & r.valve_command < 100);

r = check_flow(mk(8.9, 0), limit, pp);
assert(strcmp(r.status, 'SAFE'));

r = check_flow(mk(12, 0), limit, pp);
assert(strcmp(r.status, 'CRITICAL') & strcmp(r.action, 'SHUTDOWN'));
assert(r.valve_command == 0);

% Exactly at limit -> CRITICAL (boundary)
r = check_flow(mk(10, 0), limit, pp);
assert(strcmp(r.status, 'CRITICAL') & r.valve_command == 0);

% NaN sensor value -> fail safe; hydraulics are NaN, not garbage
r = check_flow(mk(NaN, 0), limit, pp);
assert(strcmp(r.status, 'CRITICAL') & strcmp(r.action, 'SHUTDOWN') & r.valve_command == 0);
assert(isnan(r.reynolds_number) & isnan(r.pressure_drop));

% Location passes through untouched
assert(strcmp(r.location, 'feed_pipeline'));

% The 5 contract fields come first, then the 6 hydraulic fields
r = check_flow(mk(5, 0), limit, pp);
assert(isequal(fieldnames(r), {'location';'status';'action';'valve_command';'reason'; ...
    'volumetric_flow_rate';'area';'velocity';'reynolds_number';'friction_factor';'pressure_drop'}));

% ---- Rate of change (placeholder 2 kg/s^2) ----

% 5 -> 8 kg/s in 1 s = 3 kg/s^2 -> AT_RISK though far below limit
r = check_flow(mk(8, 1), limit, pp, mk(5, 0));
assert(strcmp(r.status, 'AT_RISK') & strcmp(r.action, 'ADJUST_VALVE'));
assert(~isempty(strfind(r.reason, 'd(flow)/dt')));

% Slow rise -> SAFE
r = check_flow(mk(5.5, 1), limit, pp, mk(5, 0));
assert(strcmp(r.status, 'SAFE'));

% Fast FALL must not trip the rate check
r = check_flow(mk(5, 1), limit, pp, mk(8, 0));
assert(strcmp(r.status, 'SAFE'));

% Rate never downgrades CRITICAL
r = check_flow(mk(12, 1), limit, pp, mk(8, 0));
assert(strcmp(r.status, 'CRITICAL') & r.valve_command == 0);

% Rate limit is an argument: same jump, looser threshold -> SAFE
r = check_flow(mk(8, 1), limit, pp, mk(5, 0), struct('flow_rate_limit_kg_s2', 10));
assert(strcmp(r.status, 'SAFE'));

% ---- No previous reading: must not crash ----
r = check_flow(mk(5, 1), limit, pp, []);
assert(strcmp(r.status, 'SAFE'));
r = check_flow(mk(5, 1), limit, pp);
assert(strcmp(r.status, 'SAFE'));

% ---- Delta_t = 0 and < 0: rate skipped, no divide-by-zero ----
r = check_flow(mk(8, 5), limit, pp, mk(5, 5));
assert(strcmp(r.status, 'SAFE'));
assert(~isempty(strfind(r.reason, 'rate check skipped')));

r = check_flow(mk(8, 4), limit, pp, mk(5, 5));
assert(strcmp(r.status, 'SAFE'));
assert(~isempty(strfind(r.reason, 'rate check skipped')));

% ---- Previous reading with NaN flow: rate skipped, no crash ----
r = check_flow(mk(5, 1), limit, pp, mk(NaN, 0));
assert(strcmp(r.status, 'SAFE'));

% ---- Hydraulics: turbulent (5 kg/s) ----
% Expected values computed independently here from the textbook formulas.
D = 0.1; L = 10; rho = 1000; mu = 1e-3; eps = 4.5e-5;
A_exp  = pi * D^2 / 4;
Q_exp  = 5 / rho;
v_exp  = Q_exp / A_exp;
Re_exp = rho * v_exp * D / mu;
f_sj   = 0.25 / (log10(eps/(3.7*D) + 5.74/Re_exp^0.9))^2;   % Swamee-Jain
dp_exp = f_sj * (L/D) * (rho * v_exp^2 / 2);

r = check_flow(mk(5, 0), limit, pp);
assert(Re_exp > 4000);                                  % really turbulent
assert(abs(r.volumetric_flow_rate - Q_exp) < 1e-12);
assert(abs(r.area - A_exp) < 1e-12);
assert(abs(r.velocity - v_exp) < 1e-9);
assert(abs(r.reynolds_number - Re_exp) < 1e-6 * Re_exp);
assert(abs(r.friction_factor - f_sj) < 1e-12);          % Swamee-Jain used
assert(abs(r.pressure_drop - dp_exp) < 1e-9 * dp_exp);
assert(all(isfinite([r.volumetric_flow_rate r.area r.velocity ...
                     r.reynolds_number r.friction_factor r.pressure_drop])));
assert(r.friction_factor > 0.01 & r.friction_factor < 0.1);   % sane turbulent range

% ---- Hydraulics: laminar (0.01 kg/s) ----
r = check_flow(mk(0.01, 0), limit, pp);
assert(r.reynolds_number < 2300);
assert(abs(r.friction_factor - 64 / r.reynolds_number) < 1e-12);   % 64/Re used
assert(all(isfinite([r.velocity r.reynolds_number r.friction_factor r.pressure_drop])));
assert(r.pressure_drop > 0);

% ---- Hydraulics: transitional (approximation, must at least be finite) ----
m_trans = 3000 * mu * pi * D / 4;   % gives Re = 3000
r = check_flow(mk(m_trans, 0), limit, pp);
assert(abs(r.reynolds_number - 3000) < 1e-6);
assert(isfinite(r.friction_factor) & r.friction_factor > 0);

% ---- Zero flow: no divide-by-zero, zero pressure drop ----
r = check_flow(mk(0, 0), limit, pp);
assert(r.friction_factor == 0 & r.pressure_drop == 0 & isfinite(r.reynolds_number));

% ---- pipe_roughness override changes the turbulent friction factor ----
pp_rough = pp;  pp_rough.pipe_roughness = 1e-3;
r = check_flow(mk(5, 0), limit, pp_rough);
assert(r.friction_factor > f_sj);

% ---- Bad / missing pipe_params: safety decision still made, hydraulics NaN ----
r = check_flow(mk(5, 0), limit, []);
assert(strcmp(r.status, 'SAFE') & isnan(r.reynolds_number));
assert(~isempty(strfind(r.reason, 'hydraulics skipped')));

pp_bad = pp;  pp_bad.fluid_density = 0;
r = check_flow(mk(12, 0), limit, pp_bad);
assert(strcmp(r.status, 'CRITICAL') & isnan(r.velocity));

disp('All check_flow tests passed.');

% Headless test script for combine_checks, to_odoo_status and to_odoo_payload.
% Run: test_combine_checks

% Limits: pressure 5 bar (AT_RISK from 4.5), temperature 150 C (AT_RISK from
% ~107.7 C, margin is on the Kelvin value), flow 10 kg/s (AT_RISK from 9).
limits = struct('pressure_bar', 5, 'temperature_c', 150, 'flow_kg_s', 10);
pp = struct('pipe_diameter', 0.1, 'pipe_length', 10, ...
            'fluid_density', 1000, 'fluid_viscosity', 1e-3);

mk = @(P, T, F, t) struct('location', 'column_bottom', 'pressure', P, ...
                          'temperature', T, 'flow_rate', F, ...
                          'valve_position', 60, 'timestamp', t);

has = @(s, sub) ~isempty(strfind(s, sub));

% Baseline "everything fine" values: P 3 bar, T 80 C, F 5 kg/s

% ---- All SAFE ----
r = combine_checks(mk(3, 80, 5, 0), limits, pp);
assert(strcmp(r.status, 'SAFE') & strcmp(r.action, 'CONTINUE'));
assert(r.valve_command == 60);
assert(strcmp(r.reason, 'All checks SAFE'));
assert(strcmp(r.location, 'column_bottom'));

% ---- Exactly one non-SAFE: only that check appears in the reason ----
r = combine_checks(mk(4.7, 80, 5, 0), limits, pp);       % pressure AT_RISK
assert(strcmp(r.status, 'AT_RISK') & strcmp(r.action, 'ADJUST_VALVE'));
assert(has(r.reason, 'Pressure:') & ~has(r.reason, 'Temperature:') & ~has(r.reason, 'Flow:'));

r = combine_checks(mk(3, 120, 5, 0), limits, pp);        % temperature AT_RISK
assert(strcmp(r.status, 'AT_RISK') & has(r.reason, 'Temperature:'));
assert(~has(r.reason, 'Pressure:') & ~has(r.reason, 'Flow:'));

r = combine_checks(mk(3, 80, 9.5, 0), limits, pp);       % flow AT_RISK
assert(strcmp(r.status, 'AT_RISK') & has(r.reason, 'Flow:'));

% ---- Worst wins: CRITICAL beats AT_RISK regardless of which check is which ----
r = combine_checks(mk(6, 120, 5, 0), limits, pp);        % P CRITICAL, T AT_RISK
assert(strcmp(r.status, 'CRITICAL') & strcmp(r.action, 'SHUTDOWN') & r.valve_command == 0);

r = combine_checks(mk(4.7, 80, 12, 0), limits, pp);      % P AT_RISK, F CRITICAL
assert(strcmp(r.status, 'CRITICAL') & strcmp(r.action, 'SHUTDOWN') & r.valve_command == 0);

r = combine_checks(mk(3, 160, 5, 0), limits, pp);        % T CRITICAL only
assert(strcmp(r.status, 'CRITICAL') & r.valve_command == 0);

% ---- Reason concatenation: every non-SAFE check, none of the SAFE ones ----
r = combine_checks(mk(6, 120, 5, 0), limits, pp);        % P CRITICAL + T AT_RISK
assert(has(r.reason, 'Pressure:') & has(r.reason, 'Temperature:') & ~has(r.reason, 'Flow:'));
assert(has(r.reason, ' | '));
% order is fixed: pressure, temperature, flow
assert(strfind(r.reason, 'Pressure:') < strfind(r.reason, 'Temperature:'));

r = combine_checks(mk(4.7, 120, 9.5, 0), limits, pp);    % all three AT_RISK
assert(strcmp(r.status, 'AT_RISK'));
assert(has(r.reason, 'Pressure:') & has(r.reason, 'Temperature:') & has(r.reason, 'Flow:'));
assert(r.valve_command == 50);                            % shared adjust_valve_command

r = combine_checks(mk(6, 160, 12, 0), limits, pp);       % all three CRITICAL
assert(strcmp(r.status, 'CRITICAL') & r.valve_command == 0);
assert(has(r.reason, 'Pressure:') & has(r.reason, 'Temperature:') & has(r.reason, 'Flow:'));

% ---- Bad data in ONE channel is enough to fail safe, and is named ----
r = combine_checks(mk(3, NaN, 5, 0), limits, pp);
assert(strcmp(r.status, 'CRITICAL') & strcmp(r.action, 'SHUTDOWN') & r.valve_command == 0);
assert(has(r.reason, 'Temperature:') & ~has(r.reason, 'Pressure:'));

% ---- Previous reading is forwarded; a rate trip surfaces in the reason ----
r = combine_checks(mk(3.2, 80, 5, 1), limits, pp, mk(3.0, 80, 5, 0));   % dP/dt 20000 Pa/s
assert(strcmp(r.status, 'AT_RISK') & has(r.reason, 'dP/dt'));

% No previous reading given (omitted, or []): must not crash
r = combine_checks(mk(3, 80, 5, 1), limits, pp);
assert(strcmp(r.status, 'SAFE'));
r = combine_checks(mk(3, 80, 5, 1), limits, pp, []);
assert(strcmp(r.status, 'SAFE'));

% ---- opts are forwarded to all checks: wider margin makes 4.7 bar SAFE ----
r = combine_checks(mk(4.7, 80, 5, 0), limits, pp, [], struct('margin_fraction', 0.99));
assert(strcmp(r.status, 'SAFE'));

% ---- Individual results and flow hydraulics stay reachable ----
r = combine_checks(mk(3, 80, 5, 0), limits, pp);
assert(isequal(fieldnames(r), {'location';'status';'action';'valve_command';'reason';'checks'}));
assert(isequal(fieldnames(r.checks), {'pressure';'temperature';'flow'}));
assert(isfinite(r.checks.flow.reynolds_number) & isfinite(r.checks.flow.pressure_drop));

% ---- End to end: raw Lua units -> adapt -> combine ----
raw = struct('location', 'column_bottom', 'temperature_F', 212, ...
             'pressure_psi', 100, 'flow_gpm', 60);
[rd, fluid] = adapt_reading(raw, 1.7e9);
pp2 = struct('pipe_diameter', 0.1, 'pipe_length', 10, ...
             'fluid_density', fluid.fluid_density, 'fluid_viscosity', fluid.fluid_viscosity);
% 100 PSI = 6.89 bar, 212 F = 100 C, 60 gpm = 3.79 kg/s
% Against a 10 bar limit everything is fine ...
loose = struct('pressure_bar', 10, 'temperature_c', 150, 'flow_kg_s', 10);
r = combine_checks(rd, loose, pp2);
assert(strcmp(r.status, 'SAFE'));
% ... but against the 5 bar limit above it is over the limit -> CRITICAL
r = combine_checks(rd, limits, pp2);
assert(strcmp(r.status, 'CRITICAL') & r.valve_command == 0 & has(r.reason, 'Pressure:'));

% ==== to_odoo_status: only converted at the point of sending ====
assert(strcmp(to_odoo_status('SAFE'), 'safe'));
assert(strcmp(to_odoo_status('AT_RISK'), 'warning'));
assert(strcmp(to_odoo_status('CRITICAL'), 'critical'));
% the internal result is untouched by the mapping
r = combine_checks(mk(4.7, 80, 5, 0), limits, pp);
p = to_odoo_payload(r);
assert(strcmp(r.status, 'AT_RISK') & strcmp(p.status, 'warning'));
% unknown status errors instead of sending something invented
threw = false;
try
    to_odoo_status('WARNING');
catch
    threw = true;
end
assert(threw);

% ==== to_odoo_payload: only SHUTDOWN becomes a real 0/1 signal ====
r = combine_checks(mk(6, 80, 5, 0), limits, pp);                  % SHUTDOWN
p = to_odoo_payload(r);
assert(strcmp(p.status, 'critical') & p.shutdown_signal == 1);
assert(strcmp(p.reason, r.reason));

r = combine_checks(mk(4.7, 80, 5, 0), limits, pp);                % ADJUST_VALVE
p = to_odoo_payload(r);
assert(p.shutdown_signal == 0);                                    % no real signal
assert(has(p.reason, 'would adjust valve to 50%'));                % note in text
assert(has(p.reason, 'Pressure:'));                                % original reason kept
assert(r.valve_command == 50);                                     % internal value unchanged

r = combine_checks(mk(3, 80, 5, 0), limits, pp);                  % CONTINUE
p = to_odoo_payload(r);
assert(strcmp(p.status, 'safe') & p.shutdown_signal == 0);
assert(strcmp(p.reason, 'All checks SAFE'));

disp('All combine_checks, to_odoo_status and to_odoo_payload tests passed.');

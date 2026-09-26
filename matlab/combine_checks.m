function result = combine_checks(reading, limits, pipe_params, previous_reading, opts)
%COMBINE_CHECKS  One decision per location from pressure, temperature and flow.
%   result = combine_checks(reading, limits, pipe_params)
%   result = combine_checks(reading, limits, pipe_params, previous_reading)
%   result = combine_checks(reading, limits, pipe_params, previous_reading, opts)
%
%   reading / previous_reading  contract-format struct (see adapt_reading):
%                                 location, pressure (bar), temperature (deg C),
%                                 flow_rate (kg/s), timestamp, [valve_position]
%   limits       struct: pressure_bar, temperature_c, flow_kg_s
%   pipe_params  struct for check_flow (diameter, length, density, viscosity)
%   opts         forwarded unchanged to all three checks (safety_defaults keys)
%
%   result  location, status, action, valve_command, reason  (contract fields)
%           checks  struct with the three individual results, so callers can
%                   still reach the flow hydraulics for Odoo
%
%   Rule: WORST STATUS WINS (CRITICAL > AT_RISK > SAFE).
%     - action follows the winning status.
%     - valve_command is the smallest command among the checks at that status,
%       so the most conservative valve setting wins.
%     - reason lists EVERY non-SAFE check, not just the worst, so a CRITICAL
%       pressure with a co-occurring AT_RISK temperature reports both.
%
%   Pure function: no input(), no I/O.

    if nargin < 3
        pipe_params = [];
    end
    if nargin < 4
        previous_reading = [];
    end
    if nargin < 5
        opts = struct();
    end

    checks.pressure    = check_pressure(reading, limits.pressure_bar, previous_reading, opts);
    checks.temperature = check_temperature(reading, limits.temperature_c, previous_reading, opts);
    checks.flow        = check_flow(reading, limits.flow_kg_s, pipe_params, previous_reading, opts);

    names    = {'pressure', 'temperature', 'flow'};
    labels   = {'Pressure', 'Temperature', 'Flow'};
    statuses = {'SAFE', 'AT_RISK', 'CRITICAL'};    % index = severity rank
    actions  = {'CONTINUE', 'ADJUST_VALVE', 'SHUTDOWN'};

    ranks = zeros(1, 3);
    cmds  = zeros(1, 3);
    for k = 1:3
        r = checks.(names{k});            % dynamic field name via (...)
        ranks(k) = find(strcmp(r.status, statuses));
        cmds(k)  = r.valve_command;
    end

    worst = max(ranks);
    at_worst = (ranks == worst);

    result.location      = reading.location;
    result.status        = statuses{worst};
    result.action        = actions{worst};
    result.valve_command = min(cmds(at_worst));

    parts = {};
    for k = 1:3
        if ranks(k) > 1     % anything above SAFE
            parts{end + 1} = [labels{k} ': ' checks.(names{k}).reason]; %#ok<AGROW>
        end
    end
    if isempty(parts)
        result.reason = 'All checks SAFE';
    else
        result.reason = strjoin(parts, ' | ');
    end

    result.checks = checks;
end

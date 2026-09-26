function [reading, fluid] = adapt_reading(raw, poll_time_s)
%ADAPT_READING  Convert a raw CoppeliaSim/Odoo sample into a contract reading.
%   [reading, fluid] = adapt_reading(raw)
%   [reading, fluid] = adapt_reading(raw, poll_time_s)
%
%   raw   struct in the units the Lua scene publishes:
%           location        (char)
%           temperature_F   (deg F)
%           pressure_psi    (PSI)
%           flow_gpm        (US gallons per minute)
%           valve_position  (optional, passed through)
%           timestamp       (optional; ISO-8601 string as in /api/live_readings,
%                            a datetime, or numeric epoch seconds)
%           last_updated    (optional, older name from /api/live_pressure; used
%                            only if timestamp is absent or unparseable)
%   poll_time_s  optional epoch seconds to stamp with when last_updated is
%                absent. Defaults to "now". Injectable so tests are deterministic.
%
%   reading  the exact struct check_pressure / check_temperature / check_flow
%            expect: location, temperature (deg C), pressure (bar),
%            flow_rate (kg/s), timestamp (epoch seconds), [valve_position],
%            plus timestamp_source ('odoo_last_updated' | 'matlab_poll').
%   fluid    struct(fluid_density, fluid_viscosity) for check_flow's pipe_params.
%
%   Missing or non-numeric values become NaN, never an error: the check_*
%   functions treat NaN as bad data and fail safe to CRITICAL.
%
%   Pure function: no input(), no I/O.

    % ---- PLACEHOLDER: confirm real fluid properties with Riya before judging ----
    % Water at ~20 C. Every flow_rate and Reynolds number depends on these.
    FLUID_DENSITY   = 1000;     % kg/m^3
    FLUID_VISCOSITY = 0.001;    % Pa*s

    % Conversion factors. GPM assumes US gallons (3.785411784 L), the usual
    % convention; confirm with Riya that the scene doesn't mean imperial gallons.
    PSI_TO_BAR = 0.0689476;
    GPM_TO_M3S = 3.785411784e-3 / 60;   % 1 gal = 3.785411784e-3 m^3, 1 min = 60 s

    if nargin < 2
        poll_time_s = posixtime(datetime('now', 'TimeZone', 'UTC'));
    end

    reading.location    = raw.location;
    reading.temperature = (get_num(raw, 'temperature_F') - 32) * 5 / 9;
    reading.pressure    = get_num(raw, 'pressure_psi') * PSI_TO_BAR;
    % mass flow = volumetric flow * density (this is the only place density is
    % needed on the way in)
    reading.flow_rate   = get_num(raw, 'flow_gpm') * GPM_TO_M3S * FLUID_DENSITY;

    % Prefer the reading's own timestamp; fall back to our poll time if it is
    % missing or unparseable. A repeated timestamp gives Delta_t = 0, which the
    % rate checks skip safely.
    ts = NaN;
    if isfield(raw, 'timestamp')          % the real field name in /api/live_readings
        ts = parse_timestamp(raw.timestamp);
    end
    if ~isfinite(ts) & isfield(raw, 'last_updated')
        ts = parse_timestamp(raw.last_updated);
    end
    if isfinite(ts)
        reading.timestamp        = ts;
        reading.timestamp_source = 'odoo_last_updated';
    else
        reading.timestamp        = poll_time_s;
        reading.timestamp_source = 'matlab_poll';
    end

    if isfield(raw, 'valve_position')
        reading.valve_position = raw.valve_position;
    end

    fluid.fluid_density   = FLUID_DENSITY;
    fluid.fluid_viscosity = FLUID_VISCOSITY;
end

function v = get_num(s, name)
% Field value as a finite-or-NaN numeric scalar; NaN if missing or wrong type.
    v = NaN;
    if isfield(s, name)
        x = s.(name);   % dynamic field name via (...)
        if isnumeric(x) & isscalar(x)
            v = double(x);
        end
    end
end

function t = parse_timestamp(v)
% Epoch seconds (UTC) from a numeric, datetime or ISO-8601 string; NaN if
% unparseable. Parsed with regexp rather than datetime's timezone formats, so
% it behaves the same across MATLAB versions.
    t = NaN;
    if isnumeric(v) & isscalar(v)
        if isfinite(v)
            t = double(v);
        end
        return
    end
    if isdatetime(v) & isscalar(v)
        if isnat(v)
            return
        end
        if isempty(v.TimeZone)
            v.TimeZone = 'UTC';   % Odoo stores naive UTC
        end
        t = posixtime(v);
        return
    end
    if ~ischar(v)
        try
            v = char(v);          % e.g. a string scalar
        catch
            return
        end
    end
    % Python's isoformat() omits the fraction when it is zero, hence optional.
    % Only UTC offsets are accepted (Odoo tags readings +00:00); any other
    % offset fails the match and falls back to the poll time rather than
    % silently being read as UTC.
    tok = regexp(strtrim(v), ...
        '^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(Z|\+00:?00)?$', ...
        'tokens', 'once');
    if isempty(tok)
        return
    end
    try
        d = datetime([tok{1} 'T' tok{2}], 'InputFormat', 'yyyy-MM-dd''T''HH:mm:ss', ...
                     'TimeZone', 'UTC');
    catch
        return    % e.g. month 13
    end
    t = posixtime(d);
    if numel(tok) >= 3 & ~isempty(tok{3})
        t = t + str2double(tok{3});   % ".123456" parses as 0.123456
    end
end

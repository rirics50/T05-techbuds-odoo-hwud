function result = check_temperature(reading, temperature_safety_limit_c, previous_reading, opts)
%CHECK_TEMPERATURE  Temperature safety check: SAFE / AT_RISK / CRITICAL.
%   Mirrors check_pressure. Same tiers, same fail-safe rules.
%
%   result = check_temperature(reading, temperature_safety_limit_c)
%   result = check_temperature(reading, temperature_safety_limit_c, previous_reading)
%   result = check_temperature(reading, temperature_safety_limit_c, previous_reading, opts)
%
%   reading / previous_reading  struct with contract field names:
%                                 location    (char, required on reading)
%                                 temperature (deg C, as Odoo displays it, required)
%                                 timestamp   (seconds, needed for dT/dt)
%                                 valve_position (0-100 %, optional)
%   previous_reading            optional; pass [] or omit on the first reading.
%   opts                        optional struct overriding safety_defaults.m:
%     margin_fraction          shared with check_pressure (one place to tune both)
%     adjust_valve_command     shared with check_pressure
%     temp_rate_limit_K_per_s  *** PLACEHOLDER, NEEDS CONFIRMATION *** (Noel + Riya).
%                              The Overlay gives no temperature rate threshold.
%
%   result   struct: location, status, action, valve_command, reason
%
%   Pure function: no input(), no I/O, so it runs headless from any transport.

    if nargin < 3
        previous_reading = [];
    end
    if nargin < 4
        opts = struct();
    end
    opts = apply_defaults(opts);

    % Convert on the way in; all internal math is SI (K).
    % The limit is converted too, so the comparison is K vs K.
    T_K      = reading.temperature + 273.15;
    limit_K  = temperature_safety_limit_c + 273.15;

    result.location = reading.location;

    % Bad data must fail safe. NaN compares false with everything, so without
    % this check every comparison below would be false and NaN would read SAFE.
    bad_input = ~isnumeric(reading.temperature) | ~isscalar(reading.temperature) | ...
                ~isfinite(T_K) | ~isfinite(limit_K);

    if bad_input
        result.status        = 'CRITICAL';
        result.action        = 'SHUTDOWN';
        result.valve_command = 0;
        result.reason        = 'Invalid temperature reading or limit; failing safe';
        return
    end

    % ---- Rate of change: dT/dt = (Tnew - Told) / Delta_t  [K/s] ----
    rate_tripped = false;
    rate_note    = '';
    if isstruct(previous_reading)
        has_fields = isfield(previous_reading, 'temperature') & ...
                     isfield(previous_reading, 'timestamp') & ...
                     isfield(reading, 'timestamp');
        if has_fields
            dt    = reading.timestamp - previous_reading.timestamp;
            T_old = previous_reading.temperature + 273.15;
            % dt must be strictly positive: 0 divides by zero, negative means
            % out-of-order data. Either way skip the rate check, don't guess.
            if isscalar(dt) & isfinite(dt) & dt > 0 & isscalar(T_old) & isfinite(T_old)
                dTdt = (T_K - T_old) / dt;
                % Only a RISING rate is an overheating risk (signed compare),
                % so fast cooling doesn't trip it.
                if dTdt >= opts.temp_rate_limit_K_per_s
                    rate_tripped = true;
                    rate_note = sprintf('; dT/dt %.2f K/s >= rate limit %.2f K/s', ...
                                        dTdt, opts.temp_rate_limit_K_per_s);
                end
            else
                rate_note = '; rate check skipped (bad Delta_t or previous temperature)';
            end
        else
            rate_note = '; rate check skipped (previous reading missing fields)';
        end
    end

    % ---- Classification, most severe first ----
    % The margin is a fraction of the limit in DEG C, converted to K only for
    % the comparison (T_K is already Kelvin). 0.9 of a Kelvin value would put the
    % band ~36 K below the limit, since Kelvin's zero is far below Celsius's.
    % Assumes a positive limit in C (a fraction of a negative limit inverts).
    margin_K = opts.margin_fraction * temperature_safety_limit_c + 273.15;

    % >= (not >): sitting exactly on the limit already counts as a breach.
    if T_K >= limit_K
        result.status        = 'CRITICAL';
        result.action        = 'SHUTDOWN';
        result.valve_command = 0;   % 0 % = fully closed
        result.reason = sprintf('Temperature %.2f C >= limit %.2f C%s', ...
                                reading.temperature, temperature_safety_limit_c, rate_note);

    % A fast rise alone is a warning, not a shutdown; it can never downgrade
    % CRITICAL because that branch is checked first.
    elseif T_K >= margin_K | rate_tripped
        result.status        = 'AT_RISK';
        result.action        = 'ADJUST_VALVE';
        result.valve_command = opts.adjust_valve_command;
        result.reason = sprintf('Temperature %.2f C (limit %.2f C, margin %.0f%%)%s', ...
                                reading.temperature, temperature_safety_limit_c, ...
                                100 * opts.margin_fraction, rate_note);
    else
        result.status = 'SAFE';
        result.action = 'CONTINUE';
        % ASSUMPTION (pending Riya): hold current valve position, else 100.
        if isfield(reading, 'valve_position')
            result.valve_command = reading.valve_position;
        else
            result.valve_command = 100;
        end
        result.reason = sprintf('Temperature %.2f C below margin of limit %.2f C%s', ...
                                reading.temperature, temperature_safety_limit_c, rate_note);
    end
end

function opts = apply_defaults(opts)
% Fill any option the caller didn't set from the shared defaults.
    defaults = safety_defaults();
    names = fieldnames(defaults);
    for k = 1:numel(names)
        if ~isfield(opts, names{k})
            opts.(names{k}) = defaults.(names{k});
        end
    end
end

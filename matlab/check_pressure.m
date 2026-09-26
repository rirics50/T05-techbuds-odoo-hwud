function result = check_pressure(reading, pressure_safety_limit_bar, previous_reading, opts)
%CHECK_PRESSURE  Pressure safety check: SAFE / AT_RISK / CRITICAL.
%   result = check_pressure(reading, pressure_safety_limit_bar)
%   result = check_pressure(reading, pressure_safety_limit_bar, previous_reading)
%   result = check_pressure(reading, pressure_safety_limit_bar, previous_reading, opts)
%
%   reading / previous_reading  struct with contract field names:
%                                 location  (char, required on reading)
%                                 pressure  (bar, required)
%                                 timestamp (seconds, needed for dP/dt)
%                                 valve_position (0-100 %, optional)
%   previous_reading            optional; pass [] or omit on the first reading.
%                               Without it the rate-of-change check is skipped.
%   opts                        optional struct overriding the defaults, which live
%                               in safety_defaults.m (shared with check_temperature):
%     margin_fraction          0.9    AT_RISK starts at this fraction of the limit.
%     rate_limit_Pa_per_s      20000  *** PLACEHOLDER, NEEDS CONFIRMATION ***
%                                     (Noel + Riya). Overlay section 17 defines
%                                     dP/dt in Pa/s but gives NO safety threshold
%                                     and there is no pressure_rate_safety_limit
%                                     in the fixed user inputs. 20000 Pa/s =
%                                     0.2 bar/s is tuned to the scene's sensor noise, not an engineering value (see safety_defaults.m).
%     adjust_valve_command     50     PLACEHOLDER valve % for AT_RISK/ADJUST_VALVE.
%
%   result   struct: location, status, action, valve_command, reason
%
%   Pure function: no input(), no I/O, so it runs headless from any transport.

    % nargin lets callers omit trailing args; MATLAB has no default parameters.
    if nargin < 3
        previous_reading = [];
    end
    if nargin < 4
        opts = struct();
    end
    opts = apply_defaults(opts);

    % Convert on the way in; all internal math is SI (Pa).
    P_Pa     = reading.pressure * 1e5;
    limit_Pa = pressure_safety_limit_bar * 1e5;

    result.location = reading.location;

    % Bad data must fail safe. NaN compares false with everything, so without
    % this check every comparison below would be false and NaN would read SAFE.
    % '|' (not '||') is fine: both operands are cheap scalars.
    bad_input = ~isnumeric(reading.pressure) | ~isscalar(reading.pressure) | ...
                ~isfinite(P_Pa) | ~isfinite(limit_Pa);

    if bad_input
        result.status        = 'CRITICAL';
        result.action        = 'SHUTDOWN';
        result.valve_command = 0;
        result.reason        = 'Invalid pressure reading or limit; failing safe';
        return
    end

    % ---- Rate of change: dP/dt = (Pnew - Pold) / Delta_t  [Pa/s] ----
    rate_tripped = false;
    rate_note    = '';
    if isstruct(previous_reading)
        has_fields = isfield(previous_reading, 'pressure') & ...
                     isfield(previous_reading, 'timestamp') & ...
                     isfield(reading, 'timestamp');
        if has_fields
            dt     = reading.timestamp - previous_reading.timestamp;
            P_old  = previous_reading.pressure * 1e5;
            % dt must be strictly positive: 0 would divide by zero (Inf/NaN) and
            % negative means out-of-order data, where the sign of dP/dt is
            % meaningless. In both cases skip the rate check, don't guess.
            if isscalar(dt) & isfinite(dt) & dt > 0 & isscalar(P_old) & isfinite(P_old)
                dPdt = (P_Pa - P_old) / dt;
                % Only a RISING rate is dangerous; fast depressurising is not
                % an overpressure risk, so compare the signed value.
                if dPdt >= opts.rate_limit_Pa_per_s
                    rate_tripped = true;
                    rate_note = sprintf('; dP/dt %.0f Pa/s >= rate limit %.0f Pa/s', ...
                                        dPdt, opts.rate_limit_Pa_per_s);
                end
            else
                rate_note = '; rate check skipped (bad Delta_t or previous pressure)';
            end
        else
            rate_note = '; rate check skipped (previous reading missing fields)';
        end
    end

    % ---- Classification, most severe first ----
    margin_Pa = opts.margin_fraction * limit_Pa;

    % >= (not >): sitting exactly on the limit already counts as a breach.
    if P_Pa >= limit_Pa
        result.status        = 'CRITICAL';
        result.action        = 'SHUTDOWN';
        result.valve_command = 0;   % 0 % = fully closed
        result.reason = sprintf('Pressure %.3f bar >= limit %.3f bar%s', ...
                                reading.pressure, pressure_safety_limit_bar, rate_note);

    % A fast rise alone is a warning, not a shutdown, so it only reaches
    % AT_RISK. It can never downgrade a CRITICAL because that branch is above.
    elseif P_Pa >= margin_Pa | rate_tripped
        result.status        = 'AT_RISK';
        result.action        = 'ADJUST_VALVE';
        result.valve_command = opts.adjust_valve_command;
        result.reason = sprintf('Pressure %.3f bar (limit %.3f bar, margin %.0f%%)%s', ...
                                reading.pressure, pressure_safety_limit_bar, ...
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
        result.reason = sprintf('Pressure %.3f bar below margin of limit %.3f bar%s', ...
                                reading.pressure, pressure_safety_limit_bar, rate_note);
    end
end

function opts = apply_defaults(opts)
% Fill any option the caller didn't set. Local function: visible only in this file.
    defaults = safety_defaults();   % shared with check_temperature
    names = fieldnames(defaults);
    for k = 1:numel(names)
        if ~isfield(opts, names{k})
            opts.(names{k}) = defaults.(names{k});  % dynamic field name via (...)
        end
    end
end

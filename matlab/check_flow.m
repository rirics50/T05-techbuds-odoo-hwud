function result = check_flow(reading, flow_safety_limit_kg_s, pipe_params, previous_reading, opts)
%CHECK_FLOW  Flow safety check (SAFE / AT_RISK / CRITICAL) plus hydraulics.
%   Mirrors check_pressure / check_temperature for the safety decision, and
%   adds the Overlay section 20 hydraulic quantities as extra output fields.
%
%   result = check_flow(reading, limit_kg_s, pipe_params)
%   result = check_flow(reading, limit_kg_s, pipe_params, previous_reading)
%   result = check_flow(reading, limit_kg_s, pipe_params, previous_reading, opts)
%
%   reading / previous_reading  struct with contract field names:
%                                 location  (char, required on reading)
%                                 flow_rate (kg/s, already SI, no conversion)
%                                 timestamp (seconds, needed for d(flow)/dt)
%                                 valve_position (0-100 %, optional)
%   pipe_params   struct, all SI:
%                   pipe_diameter (m), pipe_length (m),
%                   fluid_density (kg/m^3), fluid_viscosity (Pa.s)
%                   pipe_roughness (m) OPTIONAL. Not in the Overlay's fixed user
%                   inputs; defaults to safety_defaults().pipe_roughness_m.
%                   TBD with Riya: add to Odoo inputs or hardcode per material.
%   opts          optional struct overriding safety_defaults.m:
%                   margin_fraction, adjust_valve_command (shared with the
%                   other checks) and flow_rate_limit_kg_s2 (PLACEHOLDER rate
%                   threshold, NEEDS CONFIRMATION from Noel + Riya).
%
%   result   struct with the 5 contract fields
%              location, status, action, valve_command, reason
%            plus hydraulics (NaN if flow or pipe_params are invalid):
%              volumetric_flow_rate (m^3/s), area (m^2), velocity (m/s),
%              reynolds_number, friction_factor, pressure_drop (Pa)
%
%   Pure function: no input(), no I/O, so it runs headless from any transport.

    if nargin < 3
        pipe_params = [];
    end
    if nargin < 4
        previous_reading = [];
    end
    if nargin < 5
        opts = struct();
    end
    opts = apply_defaults(opts);

    % Flow is already kg/s (SI), so no unit conversion on the way in.
    m_dot = reading.flow_rate;

    result.location = reading.location;

    % Bad data must fail safe. NaN compares false with everything, so without
    % this check every comparison below would be false and NaN would read SAFE.
    bad_input = ~isnumeric(m_dot) | ~isscalar(m_dot) | ~isfinite(m_dot) | ...
                ~isfinite(flow_safety_limit_kg_s);

    if bad_input
        result.status        = 'CRITICAL';
        result.action        = 'SHUTDOWN';
        result.valve_command = 0;
        result.reason        = 'Invalid flow reading or limit; failing safe';
        result = attach_hydraulics(result, nan_hydraulics());
        return
    end

    % ---- Hydraulics (informational; never changes the safety tier) ----
    [hyd, pipe_ok] = hydraulics(m_dot, pipe_params);
    hyd_note = '';
    if ~pipe_ok
        % Bad pipe_params must not block the safety decision, which only needs
        % flow vs limit. Report NaNs and say why.
        hyd_note = '; hydraulics skipped (invalid pipe_params)';
    end

    % ---- Rate of change: d(flow_rate)/dt = (mnew - mold) / Delta_t  [kg/s^2] ----
    rate_tripped = false;
    rate_note    = '';
    if isstruct(previous_reading)
        has_fields = isfield(previous_reading, 'flow_rate') & ...
                     isfield(previous_reading, 'timestamp') & ...
                     isfield(reading, 'timestamp');
        if has_fields
            dt    = reading.timestamp - previous_reading.timestamp;
            m_old = previous_reading.flow_rate;
            % dt must be strictly positive: 0 divides by zero, negative means
            % out-of-order data. Either way skip the rate check, don't guess.
            if isscalar(dt) & isfinite(dt) & dt > 0 & isscalar(m_old) & isfinite(m_old)
                dmdt = (m_dot - m_old) / dt;
                % Only a RISING flow is an overflow risk (signed compare), so a
                % fast drop doesn't trip it.
                if dmdt >= opts.flow_rate_limit_kg_s2
                    rate_tripped = true;
                    rate_note = sprintf('; d(flow)/dt %.2f kg/s^2 >= rate limit %.2f kg/s^2', ...
                                        dmdt, opts.flow_rate_limit_kg_s2);
                end
            else
                rate_note = '; rate check skipped (bad Delta_t or previous flow)';
            end
        else
            rate_note = '; rate check skipped (previous reading missing fields)';
        end
    end

    note = [rate_note hyd_note];

    % ---- Classification, most severe first ----
    margin = opts.margin_fraction * flow_safety_limit_kg_s;

    % >= (not >): sitting exactly on the limit already counts as a breach.
    if m_dot >= flow_safety_limit_kg_s
        result.status        = 'CRITICAL';
        result.action        = 'SHUTDOWN';
        result.valve_command = 0;   % 0 % = fully closed
        result.reason = sprintf('Flow %.3f kg/s >= limit %.3f kg/s%s', ...
                                m_dot, flow_safety_limit_kg_s, note);

    % A fast rise alone is a warning, not a shutdown; it can never downgrade
    % CRITICAL because that branch is checked first.
    elseif m_dot >= margin | rate_tripped
        result.status        = 'AT_RISK';
        result.action        = 'ADJUST_VALVE';
        result.valve_command = opts.adjust_valve_command;
        result.reason = sprintf('Flow %.3f kg/s (limit %.3f kg/s, margin %.0f%%)%s', ...
                                m_dot, flow_safety_limit_kg_s, ...
                                100 * opts.margin_fraction, note);
    else
        result.status = 'SAFE';
        result.action = 'CONTINUE';
        % ASSUMPTION (pending Riya): hold current valve position, else 100.
        if isfield(reading, 'valve_position')
            result.valve_command = reading.valve_position;
        else
            result.valve_command = 100;
        end
        result.reason = sprintf('Flow %.3f kg/s below margin of limit %.3f kg/s%s', ...
                                m_dot, flow_safety_limit_kg_s, note);
    end

    result = attach_hydraulics(result, hyd);
end

function [h, ok] = hydraulics(m_dot, p)
% Section 20 calculations. Returns NaN fields and ok=false if pipe_params is bad.
    h  = nan_hydraulics();
    ok = false;

    req = {'pipe_diameter', 'pipe_length', 'fluid_density', 'fluid_viscosity'};
    if ~isstruct(p)
        return
    end
    for k = 1:numel(req)
        % Each must exist, be a finite positive scalar (zero density or
        % diameter would divide by zero below).
        if ~isfield(p, req{k})
            return
        end
        v = p.(req{k});   % dynamic field name via (...)
        if ~(isnumeric(v) & isscalar(v) & isfinite(v) & v > 0)
            return
        end
    end
    if isfield(p, 'pipe_roughness')
        rough = p.pipe_roughness;
    else
        d = safety_defaults();
        rough = d.pipe_roughness_m;
    end
    if ~(isnumeric(rough) & isscalar(rough) & isfinite(rough) & rough >= 0)
        return
    end

    D = p.pipe_diameter;  L = p.pipe_length;
    rho = p.fluid_density; mu = p.fluid_viscosity;

    % Use the magnitude so a reverse-flow (negative) reading gives a positive
    % Re and pressure drop instead of log10 of a negative number.
    Q  = abs(m_dot) / rho;          % volumetric flow, m^3/s
    A  = pi * D^2 / 4;              % cross-section, m^2
    v  = Q / A;                     % velocity, m/s
    Re = rho * v * D / mu;

    if Re == 0
        % No flow: 64/Re would be Inf. No flow means no friction loss.
        f = 0;
    elseif Re < 2300
        f = 64 / Re;                % laminar (Hagen-Poiseuille)
    else
        % Swamee-Jain explicit turbulent approximation to Colebrook.
        % KNOWN GAP: for 2300 <= Re < 4000 (transitional) there is no standard
        % formula; we apply Swamee-Jain there as an APPROXIMATION only.
        f = 0.25 / (log10(rough / (3.7 * D) + 5.74 / Re^0.9))^2;
    end

    h.volumetric_flow_rate = Q;
    h.area                 = A;
    h.velocity             = v;
    h.reynolds_number      = Re;
    h.friction_factor      = f;
    h.pressure_drop        = f * (L / D) * (rho * v^2 / 2);   % Darcy-Weisbach, Pa
    ok = true;
end

function h = nan_hydraulics()
    h = struct('volumetric_flow_rate', NaN, 'area', NaN, 'velocity', NaN, ...
               'reynolds_number', NaN, 'friction_factor', NaN, 'pressure_drop', NaN);
end

function result = attach_hydraulics(result, h)
% Append the extra fields AFTER the 5 contract fields (extend, don't replace).
    names = fieldnames(h);
    for k = 1:numel(names)
        result.(names{k}) = h.(names{k});
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

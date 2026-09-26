function [limits, geometry] = limits_from_equipment(spec, location)
%LIMITS_FROM_EQUIPMENT  Convert an Odoo /api/equipment/<location> record to SI.
%   [limits, geometry] = limits_from_equipment(spec, location)
%
%   spec (raw Odoo units, as returned by GET /api/equipment/<name>):
%     design_pressure     PSI
%     design_temperature  deg F
%     flow_limit          kg/s   (already SI)
%     pipe_length         m      (already SI)
%     diameter            inches
%
%   limits    pressure_bar, temperature_c, flow_kg_s   (for combine_checks)
%   geometry  pipe_diameter (m), pipe_length (m)        (for check_flow)
%
%   Errors (id limits_from_equipment:*) on anything unusable. In particular a
%   limit of 0 is rejected: an unset Odoo float reads as 0.0, and a 0 limit would
%   put a location permanently CRITICAL. Refusing to start is better than that.
%
%   Pressure and temperature go through adapt_reading, so the unit conversion
%   factors still live in exactly one place.
%
%   ASSUMPTION: `diameter` is used as given (inches -> m), not reduced by wall
%   thickness. It only affects the informational hydraulics (Reynolds number and
%   pressure drop), never the safety tiers. Confirm with Riya.

    if ~isstruct(spec)
        error('limits_from_equipment:badSpec', '%s: equipment record is not a JSON object', location);
    end
    if ~isscalar(spec)
        error('limits_from_equipment:badSpec', '%s: expected a single equipment record', location);
    end
    if isfield(spec, 'error')
        error('limits_from_equipment:odooError', 'Odoo error for %s: %s', location, num2str(spec.error));
    end
    if isfield(spec, 'name')
        if ~strcmp(spec.name, location)
            error('limits_from_equipment:wrongLocation', 'Asked for %s but got %s', ...
                  location, num2str(spec.name));
        end
    end

    required = {'design_pressure', 'design_temperature', 'flow_limit', 'pipe_length', 'diameter'};
    for k = 1:numel(required)
        f = required{k};
        if ~isfield(spec, f)
            error('limits_from_equipment:missingField', '%s: record has no "%s"', location, f);
        end
        v = spec.(f);   % dynamic field name via (...)
        % Nested ifs: '&' would evaluate v > 0 even when v is not a number.
        if ~isnumeric(v)
            error('limits_from_equipment:badValue', '%s: "%s" is not a number', location, f);
        end
        if ~isscalar(v)
            error('limits_from_equipment:badValue', '%s: "%s" is empty or not a single number', location, f);
        end
        if ~isfinite(v) | v <= 0
            error('limits_from_equipment:badValue', ...
                  '%s: "%s" must be a positive number, got %g (unset in Odoo?)', location, f, v);
        end
    end

    as_raw = struct('location', location, ...
                    'pressure_psi', spec.design_pressure, ...
                    'temperature_F', spec.design_temperature, ...
                    'flow_gpm', 0);
    lim = adapt_reading(as_raw, 0);   % poll time irrelevant here

    limits = struct('pressure_bar', lim.pressure, ...
                    'temperature_c', lim.temperature, ...
                    'flow_kg_s', spec.flow_limit);

    INCH_TO_M = 0.0254;   % exact by definition
    geometry = struct('pipe_diameter', spec.diameter * INCH_TO_M, ...
                      'pipe_length', spec.pipe_length);
end

function raw = parse_live_reading(resp, location)
%PARSE_LIVE_READING  Validate one /api/live_readings/<location> response and
%   turn it into the raw struct adapt_reading expects. Pure: no network.
%
%   Real response shape (checked against the live endpoint):
%     {"location":"column_bottom", "temperature_f":180.03, "pressure_psi":56.11,
%      "flow_gpm":2.73, "timestamp":"2026-09-25T18:28:00.464397+00:00",
%      "status":"safe", "valve_state":"open"}
%   Note the lowercase 'f' in temperature_f, and that the time field is called
%   'timestamp'. status / valve_state are Odoo's own state and are ignored here.
%
%   raw   location, temperature_F, pressure_psi, flow_gpm, timestamp
%
%   Errors (error id parse_live_reading:*) on anything unusable, so the caller
%   counts it as a failed fetch instead of judging bad data as SAFE.
%
%   Why validate so hard: a record that has never received a reading returns
%   0.0 for every value with timestamp null. Zeros would read as SAFE, so a null
%   timestamp is rejected.

    if ~isstruct(resp)
        error('parse_live_reading:notObject', 'Response for %s is not a JSON object', location);
    end
    if ~isscalar(resp)
        error('parse_live_reading:notObject', 'Response for %s is not a single reading', location);
    end
    if isfield(resp, 'error')
        error('parse_live_reading:odooError', 'Odoo error for %s: %s', location, num2str(resp.error));
    end

    numeric_fields = {'temperature_f', 'pressure_psi', 'flow_gpm'};
    for k = 1:numel(numeric_fields)
        f = numeric_fields{k};
        if ~isfield(resp, f)
            error('parse_live_reading:missingField', '%s: response has no "%s"', location, f);
        end
        v = resp.(f);   % dynamic field name via (...)
        if ~(isnumeric(v) & isscalar(v))
            error('parse_live_reading:badValue', '%s: "%s" is not a number', location, f);
        end
    end

    if ~isfield(resp, 'timestamp')
        error('parse_live_reading:missingField', '%s: response has no "timestamp"', location);
    end
    ts = resp.timestamp;
    if ~ischar(ts)
        % JSON null decodes to [] : the record has no reading yet
        error('parse_live_reading:noReading', '%s: no reading yet (timestamp is null)', location);
    end
    if isempty(strtrim(ts))
        error('parse_live_reading:noReading', '%s: no reading yet (timestamp is empty)', location);
    end

    if isfield(resp, 'location')
        if ~strcmp(resp.location, location)
            error('parse_live_reading:wrongLocation', 'Asked for %s but got %s', ...
                  location, num2str(resp.location));
        end
    end

    raw = struct('location', location, ...
                 'temperature_F', resp.temperature_f, ...
                 'pressure_psi', resp.pressure_psi, ...
                 'flow_gpm', resp.flow_gpm, ...
                 'timestamp', ts);
end

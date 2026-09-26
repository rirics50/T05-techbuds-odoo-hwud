function [entries, state] = poll_cycle(cfg, settings, state)
%POLL_CYCLE  One pass over every location: fetch -> adapt -> decide -> send.
%   [entries, state] = poll_cycle(cfg, settings)
%   [entries, state] = poll_cycle(cfg, settings, state)
%
%   cfg       from load_config (odoo_base_url is used to build each URL)
%   settings  see default_settings; settings.fetch_fn is required
%   state     returned by the previous call; carries each location's previous
%             reading (for rate-of-change) and its consecutive fetch failures.
%             Omit or pass [] on the first cycle.
%
%   entries   1 x N struct array, one per location, with fields
%             location, status, odoo_status, action, valve_command, reason,
%             shutdown_signal, url, sent, send_msg, skipped, error
%
%   One location failing (fetch error, bad config, a bug) never stops the
%   others: its error is recorded in entries(k).error and the loop moves on.
%
%   No network calls here unless settings.send_http is true (see choose_sender).

    % Nested ifs, not '|': '|' evaluates both sides, and isempty(state) would
    % error when state wasn't passed.
    if nargin < 3
        state = [];
    end
    if isempty(state)
        state = struct('prev', struct(), 'fail_count', struct(), ...
                       'last_ts', struct(), 'stale_count', struct());
    end
    if isempty(settings.fetch_fn)
        error('poll_cycle:noFetch', ...
              'settings.fetch_fn is required (no live sensor source is wired in yet)');
    end

    % One poll time for the whole cycle so all five locations are comparable.
    if isempty(settings.now_fn)
        now_s = posixtime(datetime('now', 'TimeZone', 'UTC'));
    else
        now_s = settings.now_fn();
    end

    send_fn = choose_sender(settings);

    n = numel(settings.locations);
    entries = repmat(blank_entry(''), 1, n);
    for k = 1:n
        loc = settings.locations{k};
        e = blank_entry(loc);
        try
            [e, state] = process_location(e, loc, cfg, settings, state, now_s, send_fn);
        catch err
            e.error = err.message;
        end
        entries(k) = e;
    end
end

function [e, state] = process_location(e, loc, cfg, settings, state, now_s, send_fn)
    if ~isfield(state.fail_count, loc)
        state.fail_count.(loc) = 0;      % dynamic field name via (...)
    end

    fetched = false;
    try
        % TODO(fetch_fn): stub until Riya confirms the /api/live_readings/<location>
        % response shape (does it include temperature and flow yet?).
        raw = settings.fetch_fn(loc);
        [state, stale] = update_freshness(state, loc, raw);
        if stale >= settings.max_stale_polls
            error('poll_cycle:stale', 'reading unchanged for %d polls (bridge down?)', stale);
        end
        fetched = true;
        state.fail_count.(loc) = 0;
    catch err
        state.fail_count.(loc) = state.fail_count.(loc) + 1;
        e.error = ['fetch failed: ' err.message];
        if state.fail_count.(loc) < settings.max_fetch_failures
            e.skipped = true;            % keep the previous reading, post nothing
            return
        end
        % Too many consecutive failures: give up and treat as bad data. An
        % empty raw becomes all-NaN in adapt_reading, which the checks fail
        % safe to CRITICAL.
        raw = struct();
    end

    raw.location = loc;   % our loop's name is authoritative

    [reading, fluid] = adapt_reading(raw, now_s);

    pp = settings.pipe_geometry;
    if isfield(settings.pipe_geometry_by_location, loc)
        pp = settings.pipe_geometry_by_location.(loc);
    end
    pp.fluid_density   = fluid.fluid_density;
    pp.fluid_viscosity = fluid.fluid_viscosity;

    prev = [];
    if isfield(state.prev, loc)
        prev = state.prev.(loc);
    end

    result  = combine_checks(reading, settings.limits.(loc), pp, prev, settings.opts);
    payload = to_odoo_payload(result);

    if ~fetched
        % Say WHY it is CRITICAL: the bare reason would only say "invalid reading"
        payload.reason = sprintf('No usable sensor data (%s); %s', e.error, payload.reason);
    end

    e.status          = result.status;
    e.action          = result.action;
    e.valve_command   = result.valve_command;
    e.odoo_status     = payload.status;
    e.reason          = payload.reason;
    e.shutdown_signal = payload.shutdown_signal;

    e.url = odoo_url(cfg, 'safety_status', loc);   % /api/safety_status/<location>
    [ok, msg] = send_fn(e.url, payload);
    e.sent     = logical(ok);
    e.send_msg = msg;

    % Store the reading even if the send failed: the NEXT cycle's rate check
    % needs it. Not stored when the data was synthetic (fetch failed).
    if fetched
        state.prev.(loc) = reading;
    end
end

function [state, stale] = update_freshness(state, loc, raw)
% Count consecutive polls where the reading's timestamp did not change.
% Readings without a timestamp (e.g. fake test data) are never stale.
    stale = 0;
    if ~isfield(raw, 'timestamp')
        return
    end
    if isfield(state.last_ts, loc)
        if isequal(state.last_ts.(loc), raw.timestamp)
            stale = state.stale_count.(loc) + 1;
        end
    end
    state.stale_count.(loc) = stale;
    state.last_ts.(loc)     = raw.timestamp;
end

function f = choose_sender(settings)
% Precedence: explicit send_fn (tests) > real HTTP > stub.
    if ~isempty(settings.send_fn)
        f = settings.send_fn;
    elseif settings.send_http
        f = @(url, payload) post_to_odoo(url, payload, settings.http_timeout_s);
    else
        f = @send_stub;
    end
end

function [ok, msg] = send_stub(~, ~)
% ~ ignores an argument we don't need. Nothing leaves the machine.
    ok  = true;
    msg = 'stub (not sent)';
end

function [ok, msg] = post_to_odoo(url, payload, timeout_s)
% The ONLY function that touches the network. Only reachable via send_http = true.
%
% UNVERIFIED against a live endpoint: /api/safety_status is declared
% type='jsonrpc' in controllers/main.py, which expects a JSON-RPC 2.0 envelope
% with the fields inside "params". Check the first real response.
    body = struct('jsonrpc', '2.0', 'method', 'call', 'id', 1, ...
                  'params', struct('status', payload.status, 'reason', payload.reason));
    options = weboptions('MediaType', 'application/json', ...
                         'RequestMethod', 'post', 'Timeout', timeout_s);
    ok = false;
    try
        resp = webwrite(url, body, options);   % struct is encoded with jsonencode
    catch err
        msg = err.message;                     % timeout, refused, HTTP error...
        return
    end

    if isstruct(resp) & isfield(resp, 'error')
        msg = 'JSON-RPC error from Odoo';
    elseif isstruct(resp) & isfield(resp, 'result')
        res = resp.result;
        if isstruct(res) & isfield(res, 'error')
            % e.g. "latched CRITICAL - Manual Reset required": Odoo received it
            % but refused to apply it
            msg = res.error;
        elseif isstruct(res) & isfield(res, 'ok')
            ok  = logical(res.ok);
            msg = 'posted';
        else
            msg = 'unexpected result from Odoo';
        end
    else
        msg = 'unexpected response from Odoo';
    end
end

function e = blank_entry(loc)
    e = struct('location', loc, 'status', '', 'odoo_status', '', 'action', '', ...
               'valve_command', NaN, 'reason', '', 'shutdown_signal', NaN, ...
               'url', '', 'sent', false, 'send_msg', '', ...
               'skipped', false, 'error', '');
end

function [history, state] = run_safety_loop_live(settings)
%RUN_SAFETY_LOOP_LIVE  Run the real loop against Odoo's live readings.
%   run_safety_loop_live()                       run until Ctrl-C
%   run_safety_loop_live(struct('max_iterations', 3))   three cycles then stop
%   [history, state] = run_safety_loop_live(...)
%
%   READ-ONLY BY DEFAULT: it GETs /api/live_readings/<location> for each of the
%   five locations, runs adapt_reading + combine_checks, and prints the
%   decisions. It does NOT POST anything back unless you explicitly pass
%   struct('send_http', true). Leave that off until you have decided to try a
%   live POST.
%
%   Uses config.json (odoo_base_url). Any field of `settings` you pass overrides
%   the defaults, including fetch_fn and poll_interval_s.
%
%   LIMITS: by default they are loaded from Odoo (GET /api/equipment/<location>,
%   read-only) and printed at startup, so the verdicts use the real design limits.
%   struct('limits_source', 'placeholder') uses default_settings' placeholder
%   limits instead. If Odoo's limits can't be loaded the run stops with an error;
%   it never silently falls back.
%
%   Not used by the tests: test_run_safety_loop uses fake data on purpose.

    if nargin < 1
        settings = struct();
    end
    cfg = load_config();

    % Explicit, so read-only can never be lost by a change to the defaults.
    if ~isfield(settings, 'send_http')
        settings.send_http = false;
    end
    if isempty(getfield_or(settings, 'fetch_fn', []))
        timeout_s = 5;
        if isfield(settings, 'http_timeout_s')
            timeout_s = settings.http_timeout_s;
        end
        settings.fetch_fn = @(loc) fetch_live_reading(loc, cfg, timeout_s);
    end

    fprintf('LIVE run against %s\n', cfg.odoo_base_url);

    source = getfield_or(settings, 'limits_source', 'odoo');
    if strcmp(source, 'odoo')
        d = default_settings();
        locs = getfield_or(settings, 'locations', d.locations);
        [settings.limits, settings.pipe_geometry_by_location, specs] = ...
            load_limits_from_odoo(locs, cfg, getfield_or(settings, 'http_timeout_s', 5));
        fprintf('Limits loaded from Odoo (raw units as stored there):\n');
        for k = 1:numel(locs)
            sp = specs.(locs{k});
            fprintf('  %-18s %5.1f PSI  %5.1f F  flow %.3f kg/s  L %.1f m  D %.1f in\n', ...
                    locs{k}, sp.design_pressure, sp.design_temperature, ...
                    sp.flow_limit, sp.pipe_length, sp.diameter);
        end
    elseif strcmp(source, 'placeholder')
        fprintf('Limits: PLACEHOLDERS from default_settings (not Odoo''s design limits)\n');
    else
        error('run_safety_loop_live:badLimitsSource', ...
              'limits_source must be ''odoo'' or ''placeholder'', got ''%s''', source);
    end

    if settings.send_http
        fprintf('!!! send_http = true: decisions WILL be POSTed to /api/safety_status/<location>\n');
    else
        fprintf('READ-ONLY: fetching and deciding only, nothing is posted (send_http = false)\n');
    end
    fprintf('Ctrl-C to stop.\n\n');

    [history, state] = run_safety_loop(settings, cfg);
end

function v = getfield_or(s, name, default)
% s.(name) if it exists, else default. (getfield with a default doesn't exist.)
    if isfield(s, name)
        v = s.(name);
    else
        v = default;
    end
end

function [history, state] = run_safety_loop(settings, cfg)
%RUN_SAFETY_LOOP  Poll all locations forever (or max_iterations times).
%   [history, state] = run_safety_loop(settings)
%   [history, state] = run_safety_loop(settings, cfg)
%
%   settings  struct; any field you leave out comes from default_settings.
%             settings.fetch_fn is required.
%   cfg       optional; if omitted, load_config() is called ONCE here at start,
%             so a config.json edit takes effect on the next start.
%
%   history       cell array, one poll_cycle entries array per iteration
%
%   Optional hooks (see default_settings): on_cycle (display callback), stop_fn,
%   and limits_reload_fn / limits_reload_interval_s for periodic limit reloads.
%
%   Run with settings.send_http = false (the default) to test the polling and
%   decision logic with nothing leaving the machine.
%   Stop a run-forever loop with Ctrl-C.

    if nargin < 1
        settings = struct();
    end
    settings = fill_defaults(settings);
    if nargin < 2
        cfg = load_config();
    end

    history   = {};
    state = [];
    iter  = 0;
    last_reload   = tic;   % when limits were last (re)loaded, successfully or not
    last_ok       = tic;   % when they were last loaded successfully
    reload_fails  = 0;
    specs_now     = settings.limits_specs;
    while iter < settings.max_iterations
        % Nested ifs: '&' would call stop_fn even when it is empty.
        if ~isempty(settings.stop_fn)
            if settings.stop_fn()
                break
            end
        end
        t0 = tic;

        % ---- Periodic limits reload (so an Odoo limit can change mid-session) ----
        changes = {};
        if ~isempty(settings.limits_reload_fn)
            if toc(last_reload) >= settings.limits_reload_interval_s
                last_reload = tic;
                try
                    [new_limits, new_geo, new_specs] = settings.limits_reload_fn();
                    changes = diff_limits(specs_now, new_specs);
                    settings.limits = new_limits;
                    settings.pipe_geometry_by_location = new_geo;
                    specs_now = new_specs;
                    last_ok = tic;
                    reload_fails = 0;
                    for k = 1:numel(changes)
                        fprintf('*** %s\n', changes{k});
                    end
                catch err
                    % Keep judging with the previous limits; never stop mid-demo.
                    reload_fails = reload_fails + 1;
                    fprintf('!!! limits reload failed (%d in a row), keeping previous limits: %s\n', ...
                            reload_fails, err.message);
                end
            end
        end

        try
            [entries, state] = poll_cycle(cfg, settings, state);
            history{end + 1} = entries; %#ok<AGROW>
            if settings.verbose
                print_cycle(entries);
            end

            % ---- Optional display hook. Purely observational. ----
            if ~isempty(settings.on_cycle)
                info = struct('iteration', iter + 1, 'now_s', entries(1).poll_time_s, ...
                              'cfg', cfg, 'send_http', settings.send_http, ...
                              'opts', settings.opts, 'limits', settings.limits, ...
                              'limits_age_s', toc(last_ok), ...
                              'limits_reloading', ~isempty(settings.limits_reload_fn), ...
                              'limits_reload_interval_s', settings.limits_reload_interval_s, ...
                              'limits_fail_count', reload_fails, ...
                              'limit_changes', {changes});
                try
                    settings.on_cycle(entries, info);
                catch hook_err
                    fprintf('!!! display update failed (safety loop continues): %s\n', hook_err.message);
                end
            end
        catch err
            % An unexpected error must not silently kill the safety loop
            % mid-demo. Say so loudly and try again next cycle.
            fprintf('!!! poll cycle failed: %s\n', err.message);
        end
        iter = iter + 1;

        % Sleep only the remainder of the interval so cycles stay ~evenly spaced.
        pause(max(0, settings.poll_interval_s - toc(t0)));
    end
end

function settings = fill_defaults(settings)
    defaults = default_settings();
    names = fieldnames(defaults);
    for k = 1:numel(names)
        if ~isfield(settings, names{k})
            settings.(names{k}) = defaults.(names{k});
        end
    end
end

function print_cycle(entries)
    stamp = datestr(now, 'HH:MM:SS'); %#ok<TNOW1,DATST>
    for k = 1:numel(entries)
        e = entries(k);
        if ~isempty(e.error) & ~e.skipped & isempty(e.odoo_status)
            fprintf('%s %-18s ERROR    %s\n', stamp, e.location, e.error);
        elseif e.skipped
            fprintf('%s %-18s SKIPPED  %s\n', stamp, e.location, e.error);
        else
            % Show what the sender actually reported ('stub (not sent)', 'posted',
            % ...) rather than a bare "sent", which was misleading in read-only runs.
            if e.sent
                sent = e.send_msg;
            else
                sent = ['NOT SENT: ' e.send_msg];
            end
            fprintf('%s %-18s %-8s %s [%s]\n', stamp, e.location, ...
                    upper(e.odoo_status), e.reason, sent);
        end
    end
end

function model = dashboard_update(model, entries, info)
%DASHBOARD_UPDATE  Turn one poll cycle into everything the dashboard shows.
%   model = dashboard_update(model, entries, info)
%
%   model    [] on the first call, else the value returned by the previous call
%   entries  poll_cycle's output (1 x N struct array)
%   info     the struct run_safety_loop passes to on_cycle
%
%   PURE DATA: no graphics, no I/O, and NO decision-making. Every status and
%   reason shown comes straight from `entries`, which poll_cycle already
%   computed with the same code that would be sent to Odoo. This file only
%   formats and remembers history, so it can be tested with fake readings.
%
%   model fields used by dashboard_render:
%     columns, rows (N x ncols cell of char), row_colors (N x 3),
%     banner_lines (cell), banner_color, banner_fg,
%     locations, t.(loc), series.(loc).(metric), limit.(loc).(metric),
%     band.(loc).(metric), ylim.(loc).(metric), xlim

    metrics = {'temperature_c', 'pressure_bar', 'flow_kg_s'};
    statuses = {'SAFE', 'AT_RISK', 'CRITICAL'};

    if isempty(model)
        model = struct();
        model.columns = {'Status', 'Temperature', 'Pressure', 'Flow', ...
                         'Limits (T | P | flow)', 'Age', 'Reason'};
        model.max_points = 120;        % about 2 minutes at a 1 s poll
        model.t0 = NaN;
        model.last_ts = struct();
        model.last_change_s = struct();
        model.t = struct();
        model.series = struct();
        model.notice = '';
        model.notice_iter = -Inf;
    end

    n = numel(entries);
    now_s = info.now_s;
    if isnan(model.t0)
        model.t0 = now_s;
    end
    elapsed = now_s - model.t0;

    margin = margin_from_opts(info.opts);

    model.locations = cell(1, n);
    model.rows = cell(n, numel(model.columns));
    model.row_colors = zeros(n, 3);

    for k = 1:n
        e = entries(k);
        loc = e.location;
        model.locations{k} = loc;

        % ---- values (NaN when there is no reading) ----
        r = e.reading;
        raw = e.raw;
        T_c = numfield(r, 'temperature');
        P_bar = numfield(r, 'pressure');
        F_kgs = numfield(r, 'flow_rate');
        T_f = numfield(raw, 'temperature_F');
        P_psi = numfield(raw, 'pressure_psi');
        F_gpm = numfield(raw, 'flow_gpm');
        ts = numfield(r, 'timestamp');

        % ---- reading age: seconds since the timestamp last CHANGED, by our own
        % clock. Comparing the reading's timestamp with our clock would be wrong
        % whenever MATLAB's and Odoo's clocks disagree. ----
        age = NaN;
        if isfinite(ts)
            if isfield(model.last_ts, loc)
                if model.last_ts.(loc) ~= ts
                    model.last_change_s.(loc) = now_s;
                end
            else
                model.last_change_s.(loc) = now_s;
            end
            model.last_ts.(loc) = ts;
            age = now_s - model.last_change_s.(loc);
        end

        % ---- status / reason, exactly as decided by the loop ----
        if isempty(e.status)
            st = 'NO DATA';
            reason = e.error;
            color = [0.85 0.85 0.85];
        else
            st = e.status;
            reason = e.reason;
            colors = [0.78 0.92 0.78; 1.00 0.90 0.60; 0.98 0.68 0.68];   % green, amber, red
            color = colors(find(strcmp(st, statuses)), :);
        end

        % ---- limits actually used this cycle ----
        lim = e.limits;
        if isempty(lim)
            if isfield(info.limits, loc)
                lim = info.limits.(loc);
            end
        end
        if isempty(lim)
            limstr = 'n/a';
        else
            limstr = sprintf('%s C | %s bar | %s kg/s', ...
                             num('%.1f', lim.temperature_c), ...
                             num('%.2f', lim.pressure_bar), ...
                             num('%.3f', lim.flow_kg_s));
        end

        age_text = num('%.1f', age);
        if isfinite(age)
            age_text = [age_text ' s'];
        end

        model.rows(k, :) = { ...
            st, ...
            sprintf('%s F | %s C', num('%.1f', T_f), num('%.1f', T_c)), ...
            sprintf('%s PSI | %s bar', num('%.1f', P_psi), num('%.2f', P_bar)), ...
            sprintf('%s gpm | %s kg/s', num('%.2f', F_gpm), num('%.3f', F_kgs)), ...
            limstr, ...
            age_text, ...
            reason};
        model.row_colors(k, :) = color;

        % ---- history (NaN keeps a gap in the line when there is no reading) ----
        if ~isfield(model.t, loc)
            model.t.(loc) = [];
            for m = 1:numel(metrics)
                model.series.(loc).(metrics{m}) = [];
            end
        end
        model.t.(loc)(end + 1) = elapsed;
        vals = struct('temperature_c', T_c, 'pressure_bar', P_bar, 'flow_kg_s', F_kgs);
        for m = 1:numel(metrics)
            model.series.(loc).(metrics{m})(end + 1) = vals.(metrics{m});
        end
        if numel(model.t.(loc)) > model.max_points
            model.t.(loc) = model.t.(loc)(end - model.max_points + 1:end);
            for m = 1:numel(metrics)
                s = model.series.(loc).(metrics{m});
                model.series.(loc).(metrics{m}) = s(end - model.max_points + 1:end);
            end
        end

        % ---- limit line, AT_RISK band line and y-range for each chart ----
        if ~isempty(lim)
            bnd = at_risk_bands(lim, margin);
            for m = 1:numel(metrics)
                key = metrics{m};
                model.limit.(loc).(key) = lim.(key);
                model.band.(loc).(key)  = bnd.(key);
                data = model.series.(loc).(key);
                data = data(isfinite(data));
                model.ylim.(loc).(key) = padded_range([data, lim.(key), bnd.(key)]);
            end
        end
    end
    model.xlim = [max(0, elapsed - model.max_points), max(elapsed, 1)];

    % ---- banner ----
    if info.send_http
        mode = 'POSTING ON: decisions ARE being sent to Odoo';
        model.banner_color = [0.75 0.15 0.15];
    else
        mode = 'READ-ONLY: nothing is being sent to Odoo';
        model.banner_color = [0.20 0.38 0.60];
    end
    model.banner_fg = [1 1 1];

    if info.limits_reloading
        lim_text = sprintf('limits from Odoo, reloaded %d s ago (every %g s)', ...
                           round(info.limits_age_s), info.limits_reload_interval_s);
        if info.limits_fail_count > 0
            lim_text = sprintf('%s, LAST %d RELOAD(S) FAILED, using older limits', ...
                               lim_text, info.limits_fail_count);
        end
    else
        lim_text = 'limits fixed (not reloading from Odoo)';
    end
    line1 = sprintf('%s   |   %s   |   cycle %d   |   %s', ...
                    mode, info.cfg.odoo_base_url, info.iteration, lim_text);

    % A limit change stays visible for a while after it happens.
    if ~isempty(info.limit_changes)
        model.notice = strjoin(info.limit_changes, '; ');
        model.notice_iter = info.iteration;
    end
    if info.iteration - model.notice_iter < 30
        line2 = model.notice;
    else
        line2 = '';
    end
    model.banner_lines = {line1, line2};
end

function m = margin_from_opts(opts)
% The margin the checks are using: the opts override if given, else the shared default.
    d = safety_defaults();
    m = d.margin_fraction;
    if isstruct(opts)
        if isfield(opts, 'margin_fraction')
            m = opts.margin_fraction;
        end
    end
end

function v = numfield(s, name)
% Numeric scalar field, or NaN if the struct/field is missing or not a number.
    v = NaN;
    if isstruct(s)
        if isfield(s, name)
            x = s.(name);
            if isnumeric(x)
                if isscalar(x)
                    v = double(x);
                end
            end
        end
    end
end

function s = num(fmt, x)
    if isfinite(x)
        s = sprintf(fmt, x);
    else
        s = 'n/a';
    end
end

function r = padded_range(vals)
% [lo hi] covering vals with 5% padding; never a zero-height range.
    lo = min(vals);
    hi = max(vals);
    pad = 0.05 * (hi - lo);
    if pad <= 0
        pad = max(1, abs(hi) * 0.05);
    end
    r = [lo - pad, hi + pad];
end

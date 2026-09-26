function dashboard_render(h, model)
%DASHBOARD_RENDER  Push a dashboard_update model onto the window.
%   dashboard_render(h, model)   h from dashboard_create
%
%   Graphics only; no logic. NOT covered by the automated tests (needs a display).
%   Does nothing if the window has been closed.

    if ~ishandle(h.fig)
        return
    end

    set(h.banner, 'String', model.banner_lines, ...
        'BackgroundColor', model.banner_color, 'ForegroundColor', model.banner_fg);

    % Row k of BackgroundColor colours row k when there are as many colours as rows.
    set(h.table, 'Data', model.rows, 'BackgroundColor', model.row_colors);

    for c = 1:numel(h.locations)
        loc = h.locations{c};
        for r = 1:3
            key = h.metrics{r};
            if ~isfield(model.t, loc)
                continue
            end
            set(h.line(r, c), 'XData', model.t.(loc), 'YData', model.series.(loc).(key));
            set(h.ax(r, c), 'XLim', model.xlim);
            has_limit = false;
            if isfield(model, 'limit')
                if isfield(model.limit, loc)
                    has_limit = true;
                end
            end
            if has_limit
                set(h.limit(r, c), 'XData', model.xlim, 'YData', [1 1] * model.limit.(loc).(key));
                set(h.band(r, c),  'XData', model.xlim, 'YData', [1 1] * model.band.(loc).(key));
                set(h.ax(r, c), 'YLim', model.ylim.(loc).(key));
            end
        end
    end
    drawnow limitrate
end

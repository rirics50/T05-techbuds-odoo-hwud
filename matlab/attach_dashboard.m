function [settings, h] = attach_dashboard(settings)
%ATTACH_DASHBOARD  Add the dashboard window to a settings struct as hooks.
%   [settings, h] = attach_dashboard(settings)
%
%   Opens the window and sets settings.on_cycle (draw after every cycle) and
%   settings.stop_fn (end the loop when the window is closed). The decisions
%   come from the untouched safety loop; this only draws them. A drawing error
%   is caught by run_safety_loop and can never stop the loop.
%
%   Console printing is turned off by default (the window replaces it); pass
%   settings.verbose = true to keep both.

    if ~isfield(settings, 'locations')
        d = default_settings();
        settings.locations = d.locations;
    end
    if ~isfield(settings, 'verbose')
        settings.verbose = false;
    end

    h = dashboard_create(settings.locations);
    setappdata(h.fig, 'handles', h);
    setappdata(h.fig, 'model', []);

    fig = h.fig;
    settings.on_cycle = @(entries, info) draw_cycle(fig, entries, info);
    settings.stop_fn  = @() ~ishandle(fig);
end

function draw_cycle(fig, entries, info)
    if ~ishandle(fig)
        return
    end
    model = dashboard_update(getappdata(fig, 'model'), entries, info);
    setappdata(fig, 'model', model);
    dashboard_render(getappdata(fig, 'handles'), model);
end

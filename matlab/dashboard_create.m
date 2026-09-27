function h = dashboard_create(locations)
%DASHBOARD_CREATE  Build the dashboard window once. Returns a struct of handles.
%   h = dashboard_create(locations)
%
%   Layout (top to bottom): banner, status table (one row per location, colour
%   coded, with an Engineering column showing velocity/Reynolds/friction factor/
%   pressure drop/both rates - the same numbers to_engineering_payload sends to
%   Odoo, computed every cycle regardless of send_engineering), then a 3 x N grid
%   of charts (temperature, pressure, flow; one column per location), each with
%   its limit (red dashed) and AT_RISK band (amber dashed).
%
%   Graphics only. NOT covered by the automated tests: it needs a display.
%   Uses classic figure/uitable/axes so it works on older MATLAB versions too.

    n = numel(locations);
    h.locations = locations;
    h.metrics = {'temperature_c', 'pressure_bar', 'flow_kg_s'};
    labels    = {'Temperature (C)', 'Pressure (bar)', 'Flow (kg/s)'};

    h.fig = figure('Name', 'Chemical process safety: MATLAB engine', 'NumberTitle', 'off', ...
                   'Position', [30 30 1950 950], 'Color', [0.96 0.96 0.96], ...
                   'MenuBar', 'none', 'ToolBar', 'none');

    h.banner = uicontrol(h.fig, 'Style', 'text', 'Units', 'normalized', ...
                         'Position', [0.01 0.915 0.98 0.075], 'FontSize', 12, ...
                         'FontWeight', 'bold', 'HorizontalAlignment', 'left', ...
                         'String', 'Starting...');

    % Must match dashboard_update's model.columns exactly (order and count): that
    % function builds each row, this only declares the headers/widths once.
    cols = {'Status', 'Temperature', 'Pressure', 'Flow', 'Limits (T | P | flow)', ...
            'Age', 'Reason', 'Engineering'};
    h.table = uitable(h.fig, 'Units', 'normalized', 'Position', [0.01 0.60 0.98 0.30], ...
                      'ColumnName', cols, 'RowName', locations, 'FontSize', 11, ...
                      'ColumnWidth', {90, 150, 150, 160, 260, 60, 420, 460}, ...
                      'ForegroundColor', [0.05 0.05 0.05], ...   % near-black text, legible on all 4 row colors
                      'Data', repmat({''}, n, numel(cols)));

    % chart grid: rows = metrics, columns = locations
    w = 0.98 / n;
    for r = 1:3
        for c = 1:n
            ax = axes('Parent', h.fig, 'Units', 'normalized', ...
                      'Position', [0.01 + (c - 1) * w + 0.035, 0.40 - (r - 1) * 0.195, w - 0.05, 0.14], ...
                      'FontSize', 8, 'Box', 'on');
            hold(ax, 'on');
            grid(ax, 'on');
            title(ax, sprintf('%s: %s', strrep(locations{c}, '_', ' '), labels{r}), ...
                  'FontSize', 9, 'FontWeight', 'bold', 'Color', [0 0 0]);   % solid black, not the default washed-out gray
            h.ax(r, c)    = ax;
            h.line(r, c)  = plot(ax, NaN, NaN, '-', 'Color', [0.10 0.35 0.75], 'LineWidth', 1.6);
            h.limit(r, c) = plot(ax, [0 1], [NaN NaN], '--', 'Color', [0.80 0.10 0.10], 'LineWidth', 1.2);
            h.band(r, c)  = plot(ax, [0 1], [NaN NaN], '--', 'Color', [0.90 0.55 0.00], 'LineWidth', 1.2);
        end
    end

    % legend text once, in the bottom-left corner
    uicontrol(h.fig, 'Style', 'text', 'Units', 'normalized', 'Position', [0.01 0.002 0.6 0.02], ...
              'String', 'blue = reading   amber dashed = AT_RISK band starts   red dashed = safety limit (from Odoo)', ...
              'HorizontalAlignment', 'left', 'BackgroundColor', [0.96 0.96 0.96], 'FontSize', 9);
end

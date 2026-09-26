function dashboard_demo(duration_s)
%DASHBOARD_DEMO  Show the dashboard with SIMULATED readings. No Odoo, no network.
%   dashboard_demo()          runs 90 seconds
%   dashboard_demo(120)       runs 120 seconds
%
%   Same loop, checks and dashboard as live_dashboard, but the readings are
%   generated here to look like the scene's: a quiet baseline with noise, then
%   a simulated demo_spike at 25 s that ramps up, holds ~12 s and eases off.
%   Uses the PLACEHOLDER limits from default_settings, not Odoo's. Nothing is
%   posted anywhere. Use it to check the window renders before a live trial.

    if nargin < 1
        duration_s = 90;
    end

    % [temp_F  press_psi  flow_gpm  temp_range  press_range  flow_range], from the Lua scene
    scene = struct( ...
        'feed_pipeline',     [ 90 30 2.0 15  8 0.8], ...
        'column_bottom',     [170 49 2.2 22 14 1.0], ...
        'column_top',        [135 40 1.8 20 12 1.2], ...
        'bottoms_output',    [165 48 2.2 22 14 1.0], ...
        'distillate_output', [140 42 1.8 20 12 1.2]);

    t_start = posixtime(datetime('now', 'TimeZone', 'UTC'));
    settings = default_settings();
    settings.fetch_fn = @(loc) simulated_reading(loc, scene, t_start);
    settings.max_iterations = duration_s;
    settings.poll_interval_s = 1;
    settings.limits_reload_fn = [];           % fixed placeholder limits
    settings = attach_dashboard(settings);

    cfg = struct('odoo_base_url', 'http://demo (no network)', 'rosbridge_url', 'ws://demo');
    run_safety_loop(settings, cfg);
end

function raw = simulated_reading(loc, scene, t_start)
    now_s = posixtime(datetime('now', 'TimeZone', 'UTC'));
    t = now_s - t_start;

    % spike envelope: 0 before 25 s, ramps to 1 over 3 s, holds 12 s, eases off over 10 s
    if t < 25
        boil = 0;
    elseif t < 28
        boil = (t - 25) / 3;
    elseif t < 40
        boil = 1;
    elseif t < 50
        boil = 1 - (t - 40) / 10;
    else
        boil = 0;
    end

    p = scene.(loc);
    raw = struct('location', loc, ...
                 'temperature_F', p(1) + boil * p(4) + (rand * 2 - 1), ...     % +/-1 F noise
                 'pressure_psi',  p(2) + boil * p(5) + (rand - 0.5), ...       % +/-0.5 PSI
                 'flow_gpm',      p(3) + boil * p(6) + (rand * 0.6 - 0.3), ... % +/-0.3 gpm
                 'timestamp',     iso_utc(floor(now_s)));                      % bridge posts about once a second
end

function s = iso_utc(epoch_s)
    d = datetime(epoch_s, 'ConvertFrom', 'posixtime', 'TimeZone', 'UTC');
    s = sprintf('%04d-%02d-%02dT%02d:%02d:%02d+00:00', d.Year, d.Month, d.Day, ...
                d.Hour, d.Minute, floor(d.Second));
end

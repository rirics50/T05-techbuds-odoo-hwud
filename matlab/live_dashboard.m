function [history, state] = live_dashboard(settings)
%LIVE_DASHBOARD  The live loop against Odoo, shown in a window.
%   live_dashboard()
%   live_dashboard(struct('max_iterations', 120))
%   [history, state] = live_dashboard(...)
%
%   This is run_safety_loop_live (same fetching, same limits from Odoo with
%   periodic reload, same decisions, same READ-ONLY default) with a display
%   attached. It reimplements nothing: the window only draws what the loop
%   computes. Close the window to stop.
%
%   Read-only unless you pass struct('send_http', true).
%   To see the window WITHOUT Odoo or Riya, run dashboard_demo instead.

    if nargin < 1
        settings = struct();
    end
    settings = attach_dashboard(settings);
    [history, state] = run_safety_loop_live(settings);
end

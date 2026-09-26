function bands = at_risk_bands(limits, margin_fraction)
%AT_RISK_BANDS  Where the AT_RISK band starts, for drawing on a chart.
%   bands = at_risk_bands(limits, margin_fraction)
%
%   limits           pressure_bar, temperature_c, flow_kg_s
%   margin_fraction  e.g. 0.9
%   bands            same three fields: the value at which AT_RISK begins
%
%   DISPLAY ONLY: this mirrors the margin rule inside check_pressure /
%   check_temperature / check_flow (a fraction of the limit; temperature's
%   fraction is taken in deg C). The checks stay the only thing that decides a
%   status. test_dashboard checks this function against the real checks, so if a
%   check's margin rule ever changes, that test fails and this must follow.

    bands.pressure_bar  = margin_fraction * limits.pressure_bar;
    bands.temperature_c = margin_fraction * limits.temperature_c;
    bands.flow_kg_s     = margin_fraction * limits.flow_kg_s;
end

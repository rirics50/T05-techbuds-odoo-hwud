function d = safety_defaults()
%SAFETY_DEFAULTS  Single source of truth for tunable safety parameters.
%   check_pressure, check_temperature and check_flow all merge their opts over this, so
%   editing a value here tunes both functions at once.
%
%   ALL VALUES ARE PLACEHOLDERS pending confirmation from Noel + Riya, except
%   where noted. The Overlay defines the rate fields/units but no thresholds.

    % AT_RISK starts at this fraction of the safety limit (shared by both checks).
    d.margin_fraction = 0.9;

    % Valve % sent on AT_RISK / ADJUST_VALVE (shared by both checks).
    d.adjust_valve_command = 50;

    % dP/dt threshold in Pa/s (5000 Pa/s = 0.05 bar/s). GUESS, NEEDS CONFIRMATION.
    d.rate_limit_Pa_per_s = 5000;

    % dT/dt threshold in K/s (0.5 K/s = 30 K/min). GUESS, NEEDS CONFIRMATION.
    % Temperature moves far more slowly than pressure in a column, hence small.
    d.temp_rate_limit_K_per_s = 0.5;

    % dm/dt threshold in kg/s^2 for check_flow. GUESS, NEEDS CONFIRMATION.
    % Depends entirely on the plant's normal flow scale.
    d.flow_rate_limit_kg_s2 = 2.0;

    % Pipe wall roughness in m, used by check_flow's Swamee-Jain friction factor
    % (turbulent flow). 4.5e-5 m = commercial steel. PLACEHOLDER: roughness is NOT
    % in the Overlay's fixed user inputs. TBD with Riya: add it to Odoo's user
    % inputs, or hardcode per pipe material. Overridable via pipe_params.pipe_roughness.
    d.pipe_roughness_m = 4.5e-5;
end

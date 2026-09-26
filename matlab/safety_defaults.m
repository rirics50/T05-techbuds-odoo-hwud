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

    % dP/dt threshold in Pa/s (20000 Pa/s = 0.2 bar/s = 2.9 PSI/s).
    % Tuned to the CoppeliaSim scene's sensor noise, NOT to real plant physics.
    % Noise is +/-0.5 PSI per sample, so two consecutive samples differ by up to
    % 1 PSI = 6895 Pa; over the 1 s poll that is 6895 Pa/s. 20000 is ~2.9x that
    % worst case: a 1 s poll can jitter to ~0.35 s before noise alone trips it.
    % A demo_spike moves pressure ~12-14 PSI in about a second (Lua smooths 0.15
    % per step), i.e. tens of thousands of Pa/s, so real spikes still trip it.
    % Only valid for polls >= ~0.4 s apart. STILL NEEDS CONFIRMATION (Noel + Riya).
    d.rate_limit_Pa_per_s = 20000;

    % dT/dt threshold in K/s. Tuned to the scene's sensor noise, not real physics.
    % Noise is +/-1 F per sample, so consecutive samples differ by up to 2 F =
    % 1.11 K, i.e. 1.11 K/s at a 1 s poll. 3 K/s is ~2.7x that worst case (a poll
    % can jitter to ~0.37 s before noise alone trips it). A demo_spike moves
    % temperature ~20 F (~11 K) in about a second, so real spikes still trip it.
    % Only valid for polls >= ~0.4 s apart. STILL NEEDS CONFIRMATION (Noel + Riya).
    d.temp_rate_limit_K_per_s = 3;

    % dm/dt threshold in kg/s^2 for check_flow. GUESS, NEEDS CONFIRMATION.
    % Depends entirely on the plant's normal flow scale.
    d.flow_rate_limit_kg_s2 = 2.0;

    % Pipe wall roughness in m, used by check_flow's Swamee-Jain friction factor
    % (turbulent flow). 4.5e-5 m = commercial steel. PLACEHOLDER: roughness is NOT
    % in the Overlay's fixed user inputs. TBD with Riya: add it to Odoo's user
    % inputs, or hardcode per pipe material. Overridable via pipe_params.pipe_roughness.
    d.pipe_roughness_m = 4.5e-5;
end

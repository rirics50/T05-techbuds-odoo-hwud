function p = to_engineering_payload(result)
%TO_ENGINEERING_PAYLOAD  The flow hydraulics of one location, ready to POST to Odoo.
%   p = to_engineering_payload(result)   result: output of combine_checks
%
%   p.velocity          m/s
%   p.reynolds_number   dimensionless
%   p.friction_factor   dimensionless
%   p.pressure_drop     Pa
%
%   All SI. NaN (bad flow or bad pipe parameters) is kept as NaN and becomes
%   JSON null when sent; the receiver must accept null.
%
%   ASSUMED FORMAT: Riya's POST /api/engineering_results/<location> is not in her
%   repo yet. She described these fields plus temperature_rate and pressure_rate.
%   Those two rates are NOT included yet: the checks compute dP/dt and dT/dt
%   internally but do not return them, and their units (Pa/s vs PSI/s, K/s vs
%   F/s) are undecided. Add them here once both are settled.
%
%   Pure formatting: no I/O, and it never affects a status.

    f = result.checks.flow;
    p = struct('velocity',        f.velocity, ...
               'reynolds_number', f.reynolds_number, ...
               'friction_factor', f.friction_factor, ...
               'pressure_drop',   f.pressure_drop);
end

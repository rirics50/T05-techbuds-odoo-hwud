function p = to_engineering_payload(result)
%TO_ENGINEERING_PAYLOAD  One location's engineering results, ready to POST to Odoo.
%   p = to_engineering_payload(result)   result: output of combine_checks
%
%   p.velocity           m/s
%   p.reynolds_number    dimensionless
%   p.friction_factor    dimensionless
%   p.pressure_drop      Pa
%   p.temperature_rate   K/s     (check_temperature's dT/dt; NaN if it wasn't computed)
%   p.pressure_rate      Pa/s    (check_pressure's dP/dt; NaN if it wasn't computed)
%
%   CONFIRMED FORMAT (Riya, 2026-09-27): plain JSON to POST /api/engineering_results/
%   <location> (NOT the JSON-RPC envelope safety_status uses - poll_cycle's
%   post_to_odoo sends it that way because it isn't a safety verdict, i.e. this
%   struct has no 'status' field). Odoo's units match our SI internals exactly
%   (Pa/s, K/s), so temperature_rate / pressure_rate need no conversion, unlike
%   the reading fields which come from Odoo in F/PSI/gpm.
%
%   All values are SI. NaN (bad flow/pipe parameters, or no previous_reading to
%   compute a rate from) is kept as NaN and becomes JSON null when sent; the
%   receiver must accept null.
%
%   Pure formatting: no I/O, and it never affects a status.

    f = result.checks.flow;
    p = struct('velocity',         f.velocity, ...
               'reynolds_number',  f.reynolds_number, ...
               'friction_factor',  f.friction_factor, ...
               'pressure_drop',    f.pressure_drop, ...
               'temperature_rate', result.checks.temperature.rate_K_per_s, ...
               'pressure_rate',    result.checks.pressure.rate_Pa_per_s);
end

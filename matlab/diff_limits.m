function changes = diff_limits(old_specs, new_specs)
%DIFF_LIMITS  Human-readable list of Odoo limit changes between two loads.
%   changes = diff_limits(old_specs, new_specs)
%
%   old_specs / new_specs  structs by location holding the raw Odoo records
%                          (from load_limits_from_odoo's third output)
%   changes                cell array of strings, e.g.
%                          'LIMIT CHANGE feed_pipeline: design_pressure 35 -> 37 PSI'
%
%   Empty when nothing changed, or when there is no previous load to compare
%   with (the very first load is not a "change").

    changes = {};
    if ~isstruct(old_specs)
        return
    end
    if ~isstruct(new_specs)
        return
    end

    fields = {'design_pressure',    'PSI'; ...
              'design_temperature', 'F'; ...
              'flow_limit',         'kg/s'; ...
              'pipe_length',        'm'; ...
              'diameter',           'in'};
    locs = fieldnames(new_specs);
    for k = 1:numel(locs)
        loc = locs{k};
        if ~isfield(old_specs, loc)
            continue
        end
        a = old_specs.(loc);   % dynamic field name via (...)
        b = new_specs.(loc);
        for j = 1:size(fields, 1)
            f = fields{j, 1};
            if isfield(a, f) & isfield(b, f)
                if ~isequal(a.(f), b.(f))
                    changes{end + 1} = sprintf('LIMIT CHANGE %s: %s %g -> %g %s', ...
                                               loc, f, a.(f), b.(f), fields{j, 2}); %#ok<AGROW>
                end
            end
        end
    end
end

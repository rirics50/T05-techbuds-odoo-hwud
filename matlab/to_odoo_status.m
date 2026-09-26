function s = to_odoo_status(status)
%TO_ODOO_STATUS  Map an internal status to what Odoo's /api/safety_status accepts.
%   SAFE -> 'safe', AT_RISK -> 'warning', CRITICAL -> 'critical' (lowercase).
%   Odoo only knows safe/warning/critical, so this is applied ONLY at the point
%   of sending; the check_* functions keep returning SAFE/AT_RISK/CRITICAL.
%
%   PENDING Riya: whether Odoo keeps 'warning' or adopts AT_RISK. If it changes,
%   this is the only function to edit.

    switch status
        case 'SAFE'
            s = 'safe';
        case 'AT_RISK'
            s = 'warning';
        case 'CRITICAL'
            s = 'critical';
        otherwise
            % Internal code only produces the three values above, so anything
            % else is a bug. Error loudly rather than send a made-up status.
            error('to_odoo_status:unknownStatus', ...
                  'Unknown status "%s"; expected SAFE, AT_RISK or CRITICAL', ...
                  num2str(status));
    end
end

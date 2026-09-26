function p = to_odoo_payload(result)
%TO_ODOO_PAYLOAD  Turn a combined decision into what we will send to Odoo.
%   p = to_odoo_payload(result)   result: output of combine_checks
%
%   p.status           'safe' | 'warning' | 'critical'  (via to_odoo_status)
%   p.reason           result.reason; for ADJUST_VALVE a note is appended
%   p.shutdown_signal  1 only for SHUTDOWN, else 0
%
%   Only the 0/1 <location>_valve_shutdown signal exists today (no partial
%   valve), so SHUTDOWN is the only action that becomes a real command.
%   ADJUST_VALVE is informational: nothing on the other end can receive
%   "50%", so it is described in the reason text instead of sent as a signal.
%
%   Pure formatting only; no HTTP here. The POST to /api/safety_status/<location>
%   takes p.status and p.reason. shutdown_signal is for logging/tests, since
%   Odoo latches the valve itself when it receives 'critical'.

    p.status = to_odoo_status(result.status);
    p.reason = result.reason;
    if strcmp(result.action, 'ADJUST_VALVE')
        p.reason = sprintf('%s (informational: would adjust valve to %g%% if partial valve control existed)', ...
                           result.reason, result.valve_command);
    end
    p.shutdown_signal = double(strcmp(result.action, 'SHUTDOWN'));
end

% Headless test script for load_config / odoo_url. Run: test_load_config
% Uses a temp config file and restores env vars, so it never touches config.json.

% Clean slate for the env vars this test uses; restored at the end.
old_odoo = getenv('ODOO_BASE_URL');  old_ros = getenv('ROSBRIDGE_URL');
setenv('ODOO_BASE_URL', '');  setenv('ROSBRIDGE_URL', '');
cleanup = onCleanup(@() restore_env(old_odoo, old_ros));

tmp = [tempname '.json'];
write = @(txt) fileattrib_write(tmp, txt);

% ---- Reads the JSON file ----
write('{"odoo_base_url":"http://1.2.3.4:8069","rosbridge_url":"ws://1.2.3.4:9090"}');
c = load_config([], tmp);
assert(strcmp(c.odoo_base_url, 'http://1.2.3.4:8069'));
assert(strcmp(c.rosbridge_url, 'ws://1.2.3.4:9090'));

% ---- Trailing slash and whitespace are cleaned ----
write('{"odoo_base_url":"  http://1.2.3.4:8069//  ","rosbridge_url":"ws://1.2.3.4:9090/"}');
c = load_config([], tmp);
assert(strcmp(c.odoo_base_url, 'http://1.2.3.4:8069'));
assert(strcmp(c.rosbridge_url, 'ws://1.2.3.4:9090'));

% ---- Env var beats file ----
setenv('ODOO_BASE_URL', 'http://5.6.7.8:8069');
c = load_config([], tmp);
assert(strcmp(c.odoo_base_url, 'http://5.6.7.8:8069'));
assert(strcmp(c.rosbridge_url, 'ws://1.2.3.4:9090'));   % other key still from file

% ---- Override beats env var ----
c = load_config(struct('odoo_base_url', 'http://9.9.9.9:8069'), tmp);
assert(strcmp(c.odoo_base_url, 'http://9.9.9.9:8069'));
setenv('ODOO_BASE_URL', '');

% ---- Missing key / missing file: clear error, no silent default ----
write('{"odoo_base_url":"http://1.2.3.4:8069"}');
assert(throws(@() load_config([], tmp), 'load_config:missing'));
assert(throws(@() load_config([], [tempname '.json']), 'load_config:missing'));

% ---- Missing file is fine if env vars supply everything ----
setenv('ODOO_BASE_URL', 'http://5.6.7.8:8069');
setenv('ROSBRIDGE_URL', 'ws://5.6.7.8:9090');
c = load_config([], [tempname '.json']);
assert(strcmp(c.odoo_base_url, 'http://5.6.7.8:8069'));
setenv('ODOO_BASE_URL', '');  setenv('ROSBRIDGE_URL', '');

% ---- Malformed JSON is loud, not ignored ----
write('{"odoo_base_url": ');
assert(throws(@() load_config([], tmp), 'load_config:badJson'));

% ---- Wrong URL scheme is rejected ----
write('{"odoo_base_url":"192.168.0.134:8069","rosbridge_url":"ws://1.2.3.4:9090"}');
assert(throws(@() load_config([], tmp), 'load_config:badUrl'));
write('{"odoo_base_url":"http://1.2.3.4:8069","rosbridge_url":"http://1.2.3.4:9090"}');
assert(throws(@() load_config([], tmp), 'load_config:badUrl'));

% ---- The real config.json shipped with the code loads ----
c = load_config();
assert(strncmp(c.odoo_base_url, 'http', 4) & strncmp(c.rosbridge_url, 'ws', 2));

% ---- odoo_url joins cleanly ----
cfg = struct('odoo_base_url', 'http://1.2.3.4:8069');
assert(strcmp(odoo_url(cfg, '/api/safety_status/feed_pipeline'), 'http://1.2.3.4:8069/api/safety_status/feed_pipeline'));
assert(strcmp(odoo_url(cfg, 'api/safety_status/feed_pipeline'),  'http://1.2.3.4:8069/api/safety_status/feed_pipeline'));

% ---- named endpoints per location ----
assert(strcmp(odoo_url(cfg, 'safety_status', 'column_top'),  'http://1.2.3.4:8069/api/safety_status/column_top'));
assert(strcmp(odoo_url(cfg, 'equipment', 'column_top'),      'http://1.2.3.4:8069/api/equipment/column_top'));
assert(strcmp(odoo_url(cfg, 'live_readings', 'column_top'),  'http://1.2.3.4:8069/api/live_readings/column_top'));
assert(strcmp(odoo_url(cfg, 'valve_commands', 'column_top'), 'http://1.2.3.4:8069/api/valve_commands/column_top'));
assert(throws(@() odoo_url(cfg, 'safety_stauts', 'column_top'), 'odoo_url:unknownEndpoint'));   % typo
assert(throws(@() odoo_url(cfg, 'safety_status', ''), 'odoo_url:noLocation'));
assert(strcmp(odoo_url(cfg, '//api/x'),                  'http://1.2.3.4:8069/api/x'));

if exist(tmp, 'file') == 2
    delete(tmp);
end
disp('All load_config tests passed.');

% ---- local helpers (script-file local functions need R2016b+) ----
function fileattrib_write(path, txt)
    fid = fopen(path, 'w');
    fprintf(fid, '%s', txt);
    fclose(fid);
end

function tf = throws(fn, id)
    tf = false;
    try
        fn();
    catch err
        tf = strcmp(err.identifier, id);
    end
end

function restore_env(a, b)
    setenv('ODOO_BASE_URL', a);
    setenv('ROSBRIDGE_URL', b);
end

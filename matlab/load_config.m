function cfg = load_config(overrides, config_path)
%LOAD_CONFIG  Connection settings, so the venue IP is never buried in code.
%   cfg = load_config()
%   cfg = load_config(overrides)
%   cfg = load_config(overrides, config_path)
%
%   cfg.odoo_base_url   e.g. 'http://192.168.0.134:8069'   (no trailing slash)
%   cfg.rosbridge_url   e.g. 'ws://192.168.0.134:9090'      (unused on the HTTP path)
%
%   To change the IP before the demo, EDIT config.json ONLY (no code, no re-test).
%   Precedence, highest first:
%     1. overrides struct          load_config(struct('odoo_base_url','http://10.0.0.5:8069'))
%     2. environment variables     ODOO_BASE_URL, ROSBRIDGE_URL
%                                  (handy for `matlab -batch`, where there is no prompt)
%     3. config.json next to this file, or config_path if given
%
%   There is deliberately NO built-in default URL: a stale hardcoded IP that
%   silently "works" against the wrong machine is worse than a clear error.
%
%   Uses jsondecode (MATLAB R2016b or newer).

    % Nested ifs, not '|': with '|' MATLAB evaluates BOTH sides, and
    % isempty(overrides) would error when the argument wasn't passed at all.
    if nargin < 1
        overrides = struct();
    elseif isempty(overrides)
        overrides = struct();
    end
    if nargin < 2
        % mfilename('fullpath') = this file's location, so it works from any cwd.
        config_path = fullfile(fileparts(mfilename('fullpath')), 'config.json');
    end

    keys = {'odoo_base_url', 'rosbridge_url'};
    envs = {'ODOO_BASE_URL', 'ROSBRIDGE_URL'};
    schemes = {'^https?://', '^wss?://'};
    scheme_names = {'http:// or https://', 'ws:// or wss://'};

    from_file = struct();
    if exist(config_path, 'file') == 2
        try
            from_file = jsondecode(fileread(config_path));
        catch err
            % A broken file must be loud: silently ignoring it could send
            % safety commands to the wrong host.
            error('load_config:badJson', 'Could not parse %s: %s', config_path, err.message);
        end
    end

    cfg = struct();
    for k = 1:numel(keys)
        key = keys{k};
        val = '';
        if isfield(from_file, key)
            val = from_file.(key);          % dynamic field name via (...)
        end
        env = getenv(envs{k});
        if ~isempty(env)
            val = env;
        end
        if isfield(overrides, key)
            val = overrides.(key);
        end

        % Same reason as above: check the type first, in its own if, because
        % strtrim errors on a non-char (e.g. a number in the JSON).
        if ~ischar(val)
            val = '';
        end
        if isempty(strtrim(val))
            error('load_config:missing', ...
                  '%s not set. Put it in %s, set env var %s, or pass it as an override.', ...
                  key, config_path, envs{k});
        end
        val = strtrim(val);
        if isempty(regexp(val, schemes{k}, 'once'))
            error('load_config:badUrl', '%s must start with %s, got "%s"', ...
                  key, scheme_names{k}, val);
        end
        cfg.(key) = regexprep(val, '/+$', '');   % strip trailing slashes
    end
end

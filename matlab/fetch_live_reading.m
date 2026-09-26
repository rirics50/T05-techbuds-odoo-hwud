function raw = fetch_live_reading(location, cfg, timeout_s)
%FETCH_LIVE_READING  GET /api/live_readings/<location> and return a raw struct.
%   raw = fetch_live_reading(location, cfg)
%   raw = fetch_live_reading(location, cfg, timeout_s)
%
%   READ-ONLY: a single GET, nothing is sent back to Odoo.
%   The returned struct is exactly what adapt_reading takes as input, so this
%   is what goes into settings.fetch_fn (see run_safety_loop_live).
%
%   One GET per location rather than the batch /api/live_readings: it keeps
%   fetch_fn(location) independent per location, so one bad record (404, null
%   timestamp) fails only that location. At 5 small GETs a second on a LAN the
%   extra calls cost nothing.
%
%   Throws on network errors, HTTP errors (e.g. 404 for an unknown name) and
%   unusable responses; poll_cycle counts every throw as a failed fetch.

    if nargin < 3
        timeout_s = 5;
    end
    url  = odoo_url(cfg, 'live_readings', location);
    opts = weboptions('Timeout', timeout_s, 'ContentType', 'json');
    resp = webread(url, opts);           % decoded with jsondecode
    raw  = parse_live_reading(resp, location);
end

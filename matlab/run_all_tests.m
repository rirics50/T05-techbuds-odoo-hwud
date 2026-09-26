function results = run_all_tests(include_mock)
%RUN_ALL_TESTS  Run every test_*.m in this folder and print a pass/fail summary.
%   run_all_tests                 all tests that need no server (about 11 files)
%   run_all_tests('withMock')     also test_against_mock (needs the mock Odoo running,
%                                 see the header of test_against_mock.m)
%   results = run_all_tests(...)  also return one struct per test (name, passed,
%                                 seconds, message) and do NOT raise an error
%
%   Each test runs in its own fresh workspace, so one test's variables can never
%   leak into the next. A failing test does not stop the others.
%
%   With no output argument, a failure ends with an error, so
%   `matlab -batch run_all_tests` exits non-zero when anything failed.

    if nargin < 1
        include_mock = false;
    end
    if ischar(include_mock)
        include_mock = strcmpi(include_mock, 'withMock');
    end

    here = fileparts(mfilename('fullpath'));
    old_path = addpath(here);                    % so each test finds the functions it uses
    restore = onCleanup(@() path(old_path));

    listing = dir(fullfile(here, 'test_*.m'));
    names = sort(strrep({listing.name}, '.m', ''));
    skipped = {};
    if ~include_mock
        is_mock = strcmp(names, 'test_against_mock');
        skipped = names(is_mock);
        names = names(~is_mock);
    end

    fprintf('Running %d test file(s) from %s\n\n', numel(names), here);
    results = struct('name', {}, 'passed', {}, 'seconds', {}, 'message', {});
    for k = 1:numel(names)
        t0 = tic;
        [passed, msg] = run_one(names{k});
        secs = toc(t0);
        results(end + 1) = struct('name', names{k}, 'passed', passed, ...
                                  'seconds', secs, 'message', msg); %#ok<AGROW>
        if passed
            fprintf('  PASS  %-30s %5.1f s\n', names{k}, secs);
        else
            fprintf('  FAIL  %-30s %5.1f s\n        %s\n', names{k}, secs, msg);
        end
    end

    n_fail = sum(~[results.passed]);
    n_pass = numel(results) - n_fail;
    fprintf('\n%d passed, %d failed', n_pass, n_fail);
    if ~isempty(skipped)
        fprintf(', %d skipped (%s: needs the mock Odoo; run_all_tests(''withMock''))', ...
                numel(skipped), strjoin(skipped, ', '));
    end
    fprintf('\n');

    if nargout == 0
        clear results
        if n_fail > 0
            error('run_all_tests:failed', '%d test file(s) failed', n_fail);
        end
    end
end

function [passed, msg] = run_one(name)
    passed = true;
    msg = '';
    try
        exec_test(name);
    catch err
        passed = false;
        msg = err.message;
        if ~isempty(err.stack)
            msg = sprintf('%s  [%s, line %d]', msg, err.stack(1).name, err.stack(1).line);
        end
    end
end

function exec_test(test_name__)
% The test script's own variables live in THIS workspace and vanish when it returns.
% evalc also swallows the "All ... tests passed." line each test prints.
    evalc(test_name__);
end

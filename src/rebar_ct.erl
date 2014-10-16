%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
%%
%% Targets:
%% test - run common test suites in ./test
%% int_test - run suites in ./int_test
%% perf_test - run suites inm ./perf_test
%%
%% Global options:
%% verbose=1 - show output from the common_test run as it goes
%% suites="foo,bar" - run <test>/foo_SUITE and <test>/bar_SUITE
%% case="mycase" - run individual test case foo_SUITE:mycase
%% -------------------------------------------------------------------
-module(rebar_ct).

-export([ct/2]).

%% for internal use only
-export([info/2]).

-include("rebar.hrl").

%% ===================================================================
%% Public API
%% ===================================================================

ct(Config, File) ->
    TestDir = rebar_config:get_local(Config, ct_dir, "test"),
    LogDir = rebar_config:get_local(Config, ct_log_dir, "logs"),
    run_test_if_present(TestDir, LogDir, Config, File).

%% ===================================================================
%% Internal functions
%% ===================================================================

info(help, ct) ->
    ?CONSOLE(
       "Run common_test suites.~n"
       "~n"
       "Valid rebar.config options:~n"
       "  ~p~n"
       "  ~p~n"
       "  ~p~n"
       "  ~p~n"
       "Valid command line options:~n"
       "  suites=foo,bar - run <test>/foo_SUITE and <test>/bar_SUITE~n"
       "  case=\"mycase\" - run individual test case foo_SUITE:mycase~n",
       [
        {ct_dir, "itest"},
        {ct_log_dir, "test/logs"},
        {ct_extra_params, "-boot start_sasl -s myapp"},
        {ct_use_short_names, true}
       ]).

run_test_if_present(TestDir, LogDir, Config, File) ->
    case filelib:is_dir(TestDir) of
        false ->
            ?WARN("~s directory not present - skipping\n", [TestDir]),
            ok;
        true ->
            case filelib:wildcard(TestDir ++ "/*_SUITE.{beam,erl}") of
                [] ->
                    ?WARN("~s directory present, but no common_test"
                          ++ " SUITES - skipping\n", [TestDir]),
                    ok;
                _ ->
                    try
                        run_test(TestDir, LogDir, Config, File)
                    catch
                        throw:skip ->
                            ok
                    end
            end
    end.

run_test(TestDir, LogDir, Config, _File) ->
    {Cmd, RawLog} = make_cmd(TestDir, LogDir, Config),
    ?DEBUG("ct_run cmd:~n~p~n", [Cmd]),
    clear_log(LogDir, RawLog),
    Output = case rebar_log:is_verbose(Config) of
                 false ->
                     " >> " ++ RawLog ++ " 2>&1";
                 true ->
                     " 2>&1 | tee -a " ++ RawLog
             end,

    ShOpts = [{env,[{"TESTDIR", TestDir}]}, return_on_error],
    case rebar_utils:sh(Cmd ++ Output, ShOpts) of
        {ok,_} ->
            %% in older versions of ct_run, this could have been a failure
            %% that returned a non-0 code. Check for that!
            check_success_log(Config, RawLog);
        {error,Res} ->
            %% In newer ct_run versions, this may be a sign of a good compile
            %% that failed cases. In older version, it's a worse error.
            check_fail_log(Config, RawLog, Cmd ++ Output, Res)
    end.

clear_log(LogDir, RawLog) ->
    case filelib:ensure_dir(filename:join(LogDir, "index.html")) of
        ok ->
            NowStr = rebar_utils:now_str(),
            LogHeader = "--- Test run on " ++ NowStr ++ " ---\n",
            ok = file:write_file(RawLog, LogHeader);
        {error, Reason} ->
            ?ERROR("Could not create log dir - ~p\n", [Reason]),
            ?FAIL
    end.

%% calling ct with erl does not return non-zero on failure - have to check
%% log results
check_success_log(Config, RawLog) ->
    check_log(Config, RawLog, fun(Msg) -> ?CONSOLE("DONE.\n~s\n", [Msg]) end).

-type err_handler() :: fun((string()) -> no_return()).
-spec failure_logger(string(), {integer(), string()}) -> err_handler().
failure_logger(Command, {Rc, Output}) ->
    fun(_Msg) ->
            ?ABORT("~s failed with error: ~w and output:~n~s~n",
                   [Command, Rc, Output])
    end.

check_fail_log(Config, RawLog, Command, Result) ->
    check_log(Config, RawLog, failure_logger(Command, Result)).

check_log(Config,RawLog,Fun) ->
    {ok, Msg} =
        rebar_utils:sh("grep -e \"TEST COMPLETE\" -e \"{error,make_failed}\" "
                       ++ RawLog, [{use_stdout, false}]),
    MakeFailed = string:str(Msg, "{error,make_failed}") =/= 0,
    RunFailed = string:str(Msg, ", 0 failed") =:= 0,
    if
        MakeFailed ->
            show_log(Config, RawLog),
            ?ERROR("Building tests failed\n",[]),
            ?FAIL;

        RunFailed ->
            show_log(Config, RawLog),
            ?ERROR("One or more tests failed\n",[]),
            ?FAIL;

        true ->
            Fun(Msg)
    end.


%% Show the log if it hasn't already been shown because verbose was on
show_log(Config, RawLog) ->
    ?CONSOLE("Showing log\n", []),
    case rebar_log:is_verbose(Config) of
        false ->
            {ok, Contents} = file:read_file(RawLog),
            ?CONSOLE("~s", [Contents]);
        true ->
            ok
    end.

make_cmd(TestDir, RawLogDir, Config) ->
    Cwd = rebar_utils:get_cwd(),
    LogDir = filename:join(Cwd, RawLogDir),
    EbinDir = filename:absname(filename:join(Cwd, "ebin")),
    IncludeDir = filename:join(Cwd, "include"),
    Include = case filelib:is_dir(IncludeDir) of
                  true ->
                      " -include \"" ++ IncludeDir ++ "\"";
                  false ->
                      ""
              end,

    %% Check for the availability of ct_run; if we can't find it, generate a
    %% warning and use the old school, less reliable approach to running CT.
    BaseCmd = case os:find_executable("ct_run") of
                  false ->
                      "erl -noshell -s ct_run script_start -s erlang halt";
                  _ ->
                      "ct_run -noshell"
              end,

    %% Add the code path of the rebar process to the code path. This
    %% includes the dependencies in the code path. The directories
    %% that are part of the root Erlang install are filtered out to
    %% avoid duplication
    R = code:root_dir(),
    NonLibCodeDirs = [P || P <- code:get_path(), not lists:prefix(R, P)],
    CodeDirs = [io_lib:format("\"~s\"", [Dir]) ||
                   Dir <- [EbinDir|NonLibCodeDirs]],
    CodePathString = string:join(CodeDirs, " "),
    Cmd = case get_ct_specs(Config, Cwd) of
              undefined ->
                  ?FMT("~s"
                       " -pa ~s"
                       " ~s"
                       " ~s"
                       " -logdir \"~s\""
                       " -env TEST_DIR \"~s\"",
                       [BaseCmd,
                        CodePathString,
                        Include,
                        build_name(Config),
                        LogDir,
                        filename:join(Cwd, TestDir)]) ++
                      get_cover_config(Config, Cwd) ++
                      get_ct_config_file(TestDir) ++
                      get_config_file(TestDir) ++
                      get_suites(Config, TestDir) ++
                      get_case(Config);
              SpecFlags ->
                  ?FMT("~s"
                       " -pa ~s"
                       " ~s"
                       " ~s"
                       " -logdir \"~s\""
                       " -env TEST_DIR \"~s\"",
                       [BaseCmd,
                        CodePathString,
                        Include,
                        build_name(Config),
                        LogDir,
                        filename:join(Cwd, TestDir)]) ++
                      SpecFlags ++ get_cover_config(Config, Cwd)
          end,
    Cmd1 = Cmd ++ get_extra_params(Config),
    RawLog = filename:join(LogDir, "raw.log"),
    {Cmd1, RawLog}.

build_name(Config) ->
    case rebar_config:get_local(Config, ct_use_short_names, false) of
        true -> "-sname test";
        false -> " -name test@" ++ net_adm:localhost()
    end.

get_extra_params(Config) ->
    case rebar_config:get_local(Config, ct_extra_params, undefined) of
        undefined ->
            "";
        Defined ->
            " " ++ Defined
    end.

get_ct_specs(Config, Cwd) ->
    case collect_glob(Config, Cwd, ".*\.test\.spec\$") of
        [] ->
            ?DEBUG("No ct spec found ~s~n", [Cwd]),
            undefined;
        [Spec] ->
            ?DEBUG("Found ct spec file ~s~n", [Spec]),
            " -spec " ++ Spec;
        Specs ->
            ?DEBUG("Multiple ct spec files found ~p~n", [Specs]),
            " -spec " ++
                lists:flatten([io_lib:format("~s ", [Spec]) || Spec <- Specs])
    end.

get_cover_config(Config, Cwd) ->
    case rebar_config:get_local(Config, cover_enabled, false) of
        false ->
            "";
        true ->
            case collect_glob(Config, Cwd, ".*cover\.spec\$") of
                [] ->
                    ?DEBUG("No cover spec found: ~s~n", [Cwd]),
                    "";
                [Spec] ->
                    ?DEBUG("Found cover file ~s~n", [Spec]),
                    " -cover " ++ Spec;
                Specs ->
                    ?ABORT("Multiple cover specs found: ~p~n", [Specs])
            end
    end.

collect_glob(Config, Cwd, Glob) ->
    {true, Deps} = rebar_deps:get_deps_dir(Config),
    filelib:fold_files(Cwd, Glob, true, fun(F, Acc) ->
        %% Ignore any specs under the Deps directory.
        case string:str(F, Deps) of
            1 ->
                Acc;                % This path is under the deps directory
            0 ->
                [F | Acc]           % This path is not under the deps directory
        end
    end, []).

get_ct_config_file(TestDir) ->
    Config = filename:join(TestDir, "test.config"),
    case filelib:is_regular(Config) of
        false ->
            " ";
        true ->
            " -ct_config " ++ Config
    end.

get_config_file(TestDir) ->
    Config = filename:join(TestDir, "app.config"),
    case filelib:is_regular(Config) of
        false ->
            " ";
        true ->
            " -config " ++ Config
    end.

get_suites(Config, TestDir) ->
    case get_suites(Config) of
        undefined ->
            " -dir " ++ TestDir;
        Suites ->
            Suites1 = string:tokens(Suites, ","),
            Suites2 = [find_suite_path(Suite, TestDir) || Suite <- Suites1],
            string:join([" -suite"] ++ Suites2, " ")
    end.

get_suites(Config) ->
    case rebar_config:get_global(Config, suites, undefined) of
        undefined ->
            rebar_config:get_global(Config, suite, undefined); 
        Suites ->
            Suites
    end.

find_suite_path(Suite, TestDir) ->
    Path = filename:join(TestDir, Suite ++ "_SUITE.erl"),
    case filelib:is_regular(Path) of
        false ->
            ?WARN("Suite ~s not found\n", [Suite]),
            %% Note - this throw is caught in run_test_if_present/3;
            %% this solution was easier than refactoring the entire module.
            throw(skip);
        true ->
            Path
    end.

get_case(Config) ->
    case rebar_config:get_global(Config, 'case', undefined) of
        undefined ->
            "";
        Case ->
            " -case " ++ Case
    end.

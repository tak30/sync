%% vim: ts=4 sw=4 et

-module(sync_scanner).
-behaviour(gen_server).
-include_lib("kernel/include/file.hrl").

-compile([export_all, nowarn_export_all]).

%% API
-export([
    start_link/0,
    rescan/0,
    info/0,
    queue_size/0,
    enable_patching/0,
    pause/0,
    unpause/0
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3,
    set_growl/1,
    get_growl/0,
    set_log/1,
    get_log/0
]).

-define(SERVER, ?MODULE).
-define(PRINT(Var), io:format("DEBUG: ~p:~p - ~p~n~n ~p~n~n", [?MODULE, ?LINE, ??Var, Var])).
-define(LOG_OR_GROWL_ON(Val),Val==true;Val==all;Val==skip_success;is_list(Val),Val=/=[]).
-define(LOG_OR_GROWL_OFF(Val),Val==false;F==none;F==[]).

-type timestamp() :: file:date_time() | 0.

-record(state, {
    modules = [] :: [module()],
    src_dirs = [] :: [file:filename()],
    src_files = [] :: [file:filename()],
    hrl_dirs = [] :: [file:filename()],
    hrl_files = [] :: [file:filename()],
    beam_lastmod = undefined :: [{module(), timestamp()}] | undefined,
    src_file_lastmod = [] :: [{file:filename(), timestamp()}],
    hrl_file_lastmod = [] :: [{file:filename(), timestamp()}],
    timers = [],
    patching = false,
    paused = false,
    sync_method = scanner,
    modified_files = [] :: [file:filename()],
    fsevents_pids = [],
    action_queue = queue:new()
}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


rescan() ->
    gen_server:cast(?SERVER, discover_modules),
    gen_server:cast(?SERVER, discover_src_dirs),
    gen_server:cast(?SERVER, discover_src_files),
    case sync_utils:get_env(sync_method, scanner) of
        scanner ->
            io:format("Scanning source files...~n"),
            gen_server:cast(?SERVER, compare_src_files),
            gen_server:cast(?SERVER, compare_beams),
            gen_server:cast(?SERVER, compare_hrl_files_init),
            ok;
        _ ->
            io:format("Listening on fsevents...~n"),
            ok
    end,
    gen_server:cast(?SERVER, notify_when_empty).

unpause() ->
    gen_server:cast(?SERVER, unpause),
    ok.

pause() ->
    sync_notify:log_success("Pausing Sync. Call sync:go() to restart~n"),
    sync_notify:growl_success("Pausing Sync"),
    gen_server:cast(?SERVER, pause),
    ok.

info() ->
    io:format("Sync Info...~n"),
    gen_server:cast(?SERVER, info),
    ok.

queue_size() ->
    gen_server:call(?SERVER, queue_size).

set_growl(T) when ?LOG_OR_GROWL_ON(T) ->
    sync_utils:set_env(growl,all),
    sync_notify:growl_success("Sync","Desktop Notifications Enabled"),
    sync_utils:set_env(growl,T),
    ok;
set_growl(F) when ?LOG_OR_GROWL_OFF(F) ->
    sync_utils:set_env(growl,all),
    sync_notify:growl_success("Sync","Desktop Notifications Disabled"),
    sync_utils:set_env(growl,none),
    ok.

get_growl() ->
    sync_utils:get_env(growl, all).

set_log(T) when ?LOG_OR_GROWL_ON(T) ->
    sync_utils:set_env(log, T),
    sync_notify:log_success("Console Notifications Enabled~n"),
    ok;
set_log(F) when ?LOG_OR_GROWL_OFF(F) ->
    sync_notify:log_success("Console Notifications Disabled~n"),
    sync_utils:set_env(log, none),
    ok.

get_log() ->
    sync_utils:get_env(log, all).


enable_patching() ->
    gen_server:cast(?SERVER, enable_patching),
    ok.

init([]) ->
    %% Trap exits to catch failing processes...
    erlang:process_flag(trap_exit, true),

    %% Kick off the discovery process...
    rescan(),

    %% Display startup message...
    sync_notify:startup(get_growl()),

    {ok, #state{
        sync_method = sync_utils:get_env(sync_method, scanner)
    }}.

handle_call(queue_size, _From, State) ->
    Size = queue:len(State#state.action_queue),
    {reply, Size, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(notify_when_empty, State) ->
    case queue:len(State#state.action_queue) of
        0 ->
            io:format("~nSync Queue is empty. Sync is ready and actively watching for changes...~n"),
            NewTimers = proplists:delete(notify_when_empty, State#state.timers),
            NewState = State#state{timers=NewTimers},
            {noreply, NewState};
        _ ->
            NewTimers = schedule_cast(notify_when_empty, 100, State#state.timers),
            NewState = State#state{timers=NewTimers},
            {noreply, NewState}
    end;
handle_cast(pause, State) ->
    {noreply, State#state {paused=true}};
handle_cast(unpause, State) ->
    {noreply, State#state {paused=false}};
handle_cast(_, State) when State#state.paused==true ->
    %% If paused, just absorb the request and do nothing
    {noreply, State};
handle_cast(info, State) ->
    io:format("Modules: ~p~n", [State#state.modules]),
    io:format("Source Dirs: ~p~n", [State#state.src_dirs]),
    io:format("Source Files: ~p~n", [State#state.src_files]),
    io:format("Queue Size: ~p~n", [queue:len(State#state.action_queue)]),
    {noreply, State};

handle_cast(enable_patching, State) ->
    NewState = State#state { patching = true },
    {noreply, NewState};

handle_cast(process_queue, State) ->
    NewState = case queue:out(State#state.action_queue) of
        {empty, _} ->
            State;
        {{value, Action}, NewQ} ->
            State2 = State#state{action_queue=NewQ},
            process_queue_item(Action, State2)
    end,
    NewTimers = schedule_cast(process_queue, 100, State#state.timers),
    NewState2 = NewState#state{timers=NewTimers},
    {noreply, NewState2};

handle_cast(fsevents_modified_files, State = #state{modified_files=Files}) when Files =/= [] ->
    #state{patching=Patching, src_files=SrcFiles, modules=OldModules} = State,
    Recompile = fun(F, P) ->
        recompile_src_file(F, P),
        {_, M} = determine_compile_fun_and_module_name(F),
        M
    end,

    NewModules1 = lists:foldl(fun
        (FileName, Acc) ->
            case filename:extension(FileName) of
                Ext when Ext == ".erl"; Ext == ".dtl"; Ext == ".lfe"; Ext == ".ex" ->
                    M = Recompile(FileName, Patching),
                    [M | Acc];
                ".hrl" ->
                    WhoInclude = who_include(FileName, SrcFiles),
                    [Recompile(SrcFile, Patching) || SrcFile <- WhoInclude] ++ Acc;
                _ ->
                    Acc
            end
    end, [], Files),

    %% It's possible that this module is not known to sync, if yes, add it to modules list
    Filter = fun(M) ->
        lists:member(M, OldModules) /= true
    end,
    NewModules = case lists:filter(Filter, NewModules1) of
        [] -> OldModules;
        R -> lists:usort(OldModules ++ R)
    end,

    NewState = State#state{modified_files = [], modules = NewModules},
    {noreply, NewState};

handle_cast(Action, State) ->
    Q = State#state.action_queue,
    NewState = case queue:member(Action, Q) of
        true ->
            State;
        false ->
            NewTimers = schedule_cast(process_queue, 100, State#state.timers),
            NewQ = queue:in(Action, Q),
            State#state{action_queue=NewQ, timers=NewTimers}
    end,
    {noreply, NewState}.


process_queue_item(discover_modules, State) ->

    %% Get a list of all loaded non-system modules.
    Modules = (erlang:loaded() -- sync_utils:get_system_modules()),

    %% Delete excluded modules/applications
    FilteredModules = filter_modules_to_scan(Modules),

    %% Schedule the next interval...
    NewTimers = case State#state.sync_method of
        scanner -> schedule_cast(discover_modules, 30000, State#state.timers);
        _ -> proplists:delete(discover_modules, State#state.timers)
    end,

    %% Return with updated modules...
    State#state { modules=FilteredModules, timers=NewTimers };

process_queue_item(discover_src_dirs, State) ->
    {noreply, NewState} = case application:get_env(sync, src_dirs) of
        undefined ->
            discover_source_dirs(State, [], []);
        {ok, {add, DirsAndOpts}} ->
            discover_source_dirs(State, dirs(DirsAndOpts), []);
        {ok, {replace, DirsAndOpts}} ->
            discover_source_dirs(State, [], dirs(DirsAndOpts))
    end,
    NewState;

process_queue_item(discover_src_files, State) ->
    %% For each source dir, get a list of source files...
    F = fun(X, Acc) ->
        sync_utils:wildcard(X, ".*\\.(erl|dtl|lfe|ex)$") ++ Acc
    end,
    ErlFiles = lists:usort(lists:foldl(F, [], State#state.src_dirs)),

    %% For each include dir, get a list of hrl files...
    Fhrl = fun(X, Acc) ->
        sync_utils:wildcard(X, ".*\\.hrl$") ++ Acc
    end,
    HrlFiles = lists:usort(lists:foldl(Fhrl, [], State#state.hrl_dirs)),

    %% Schedule the next interval...
    NewTimers = case State#state.sync_method of
        scanner -> schedule_cast(discover_src_files, 5000, State#state.timers);
        _ -> proplists:delete(discover_src_files, State#state.timers)
    end,

    %% Return with updated files...
    State#state { src_files=ErlFiles, hrl_files=HrlFiles, timers=NewTimers };

process_queue_item(compare_beams, State) ->
    %% Create a list of beam file lastmod times, but filter out modules not having 
    %% a valid beam file reference.
    F = fun(X) ->
        case code:which(X) of
            Beam when is_list(Beam) ->
                case filelib:last_modified(Beam) of
                    0 ->
                        false; %% file not found
                    LastMod ->
                        {true, {X, LastMod}}
                end;
            _Other ->
                false %% non_existing | cover_compiled | preloaded
        end
    end,
    NewBeamLastMod = lists:usort(lists:filtermap(F, State#state.modules)),

    %% Compare to previous results, if there are changes, then reload
    %% the beam...
    process_beam_lastmod(State#state.beam_lastmod, NewBeamLastMod, State#state.patching),

    %% Schedule the next interval...
    NewTimers = case State#state.sync_method of
        scanner -> schedule_cast(compare_beams, 2000, State#state.timers);
        _ -> proplists:delete(compare_beams, State#state.timers)
    end,

    %% Return with updated beam lastmod...
    State#state { beam_lastmod=NewBeamLastMod, timers=NewTimers };

process_queue_item(compare_src_files, State) ->
    %% Create a list of file lastmod times...
    F = fun(X) ->
        LastMod = filelib:last_modified(X),
        {X, LastMod}
    end,
    NewSrcFileLastMod = lists:usort([F(X) || X <- State#state.src_files]),

    %% Compare to previous results, if there are changes, then recompile the file...
    process_src_file_lastmod(State#state.src_file_lastmod, NewSrcFileLastMod, State#state.patching),

    %% Schedule the next interval...
    NewTimers = schedule_cast(compare_src_files, 1000, State#state.timers),

    %% Return with updated src_file lastmod...
    State#state { src_file_lastmod=NewSrcFileLastMod, timers=NewTimers };

process_queue_item(compare_hrl_files_init, State) ->
    process_queue_item({compare_hrl_files, init}, State);
process_queue_item(compare_hrl_files, State) ->
    process_queue_item({compare_hrl_files, normal}, State);
process_queue_item({compare_hrl_files, Method}, State) ->
    %% Create a list of file lastmod times...
    F = fun(X) ->
        LastMod = filelib:last_modified(X),
        {X, LastMod}
    end,
    NewHrlFileLastMod = lists:usort([F(X) || X <- State#state.hrl_files]),

    %% Compare to previous results, if there are changes, then recompile src files that depends
    process_hrl_file_lastmod(State#state.hrl_file_lastmod, NewHrlFileLastMod, State#state.src_files, State#state.patching, Method),
    
    %% Schedule the next interval...
    NewTimers = schedule_cast(compare_hrl_files, 2000, State#state.timers),

    %% Return with updated hrl_file lastmod...
    State#state { hrl_file_lastmod=NewHrlFileLastMod, timers=NewTimers }.

dirs(DirsAndOpts) ->
    [begin
         sync_options:set_options(Dir, Opts),

         %% ensure module out path exists & in our code list
         case proplists:get_value(outdir, Opts) of
             undefined ->
                 true;
             Path ->
                 ok = filelib:ensure_dir(filename:join(Path, "sample")),
                 true = code:add_pathz(Path)
         end,
         Dir 
     end || {Dir, Opts} <- DirsAndOpts].

handle_info({_Pid, {fs,file_event}, {FileName, _Events}},
        #state{modified_files = OldModFiles} = State) ->

    %% Process the modified files event about a second later. Just
    %% to thaw all events happening on a file
    {noreply, State#state{
        modified_files = lists:usort([FileName | OldModFiles]),
        timers = schedule_cast(fsevents_modified_files, 1000, State#state.timers)
    }};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% PRIVATE FUNCTIONS %%%

schedule_cast(Msg, Default, Timers) ->
    %% Cancel the old timer...
    TRef = proplists:get_value(Msg, Timers),
    timer:cancel(TRef),

    %% Lookup the interval...
    IntervalKey = list_to_atom(atom_to_list(Msg) ++ "_interval"),
    Interval = sync_utils:get_env(IntervalKey, Default),

    %% Schedule the call...
    {ok, NewTRef} = timer:apply_after(Interval, gen_server, cast, [?SERVER, Msg]),

    %% Return the new timers structure...
    lists:keystore(Msg, 1, Timers, {Msg, NewTRef}).

process_beam_lastmod(A, B, EnablePatching) ->
    process_beam_lastmod(A, B, EnablePatching, {undefined, []}).

process_beam_lastmod([{Module, LastMod}|T1], [{Module, LastMod}|T2], EnablePatching, Acc) ->
    %% Beam hasn't changed, do nothing...
    process_beam_lastmod(T1, T2, EnablePatching, Acc);
process_beam_lastmod([{Module, _}|T1], [{Module, _}|T2], EnablePatching, {FirstBeam, OtherBeams}) ->
    %% Beam has changed, reload...
    Acc1 = case code:get_object_code(Module) of
        error ->
            Msg = io_lib:format("Error loading object code for ~p~n", [Module]),
            sync_notify:log_errors(Msg),
            sync_notify:growl_errors(Msg),
            {FirstBeam, OtherBeams};

        {Module, Binary, Filename} ->
            code:load_binary(Module, Filename, Binary),

            %% If patching is enabled, then reload the module across *all* connected
            %% erlang VMs, and save the compiled beam to disk.
            case EnablePatching of
                true ->
                    {ok, NumNodes} = load_module_on_all_nodes(Module),
                    Msg = io_lib:format("~s: Reloaded on ~p nodes! (Beam changed.)~n", [Module, NumNodes]),
                    sync_notify:log_success(Msg);
                false ->
                    %% Print a status message...
                    Msg = io_lib:format("~s: Reloaded! (Beam changed.)~n", [Module]),
                    sync_notify:log_success(Msg)
            end,
            case FirstBeam of
               undefined -> {Module, OtherBeams};
               _ -> {FirstBeam, [Module | OtherBeams] }
           end
    end,
    process_beam_lastmod(T1, T2, EnablePatching, Acc1);

process_beam_lastmod([{Module1, LastMod1}|T1], [{Module2, LastMod2}|T2], EnablePatching, Acc) ->
    %% Lists are different, advance the smaller one...
    case Module1 < Module2 of
        true ->
            process_beam_lastmod(T1, [{Module2, LastMod2}|T2], EnablePatching, Acc);
        false ->
            process_beam_lastmod([{Module1, LastMod1}|T1], T2, EnablePatching, Acc)
    end;
process_beam_lastmod(A, B, EnablePatching, Acc) when A =:= []; B =:= [] ->
    MsgAdd = case EnablePatching of
                 true -> " on " ++ integer_to_list(length(get_nodes())) ++ " nodes.";
                 false -> "."
             end,
    %% Done.
    case Acc of
        {undefined, []} ->
            nop; % nothing changed
        {FirstBeam, []} ->
            %% Print a status message...
            sync_notify:growl_success("Reloaded " ++ atom_to_list(FirstBeam) ++ MsgAdd),
            fire_onsync([FirstBeam]);

        {FirstBeam, N} ->
            %% Print a status message...
            sync_notify:growl_success("Reloaded " ++ atom_to_list(FirstBeam) ++
                              " and " ++ integer_to_list(erlang:length(N)) ++ " other beam files" ++ MsgAdd),
            fire_onsync([FirstBeam | N])
    end,
    ok;
process_beam_lastmod(undefined, _Other, _, _) ->
    %% First load, do nothing.
    ok.

fire_onsync(Modules) ->
    case sync_options:get_onsync() of
        undefined -> ok;
        Funs when is_list(Funs) -> onsync_apply_list(Funs, Modules);
        Fun -> onsync_apply(Fun, Modules)
    end.

onsync_apply_list(Funs, Modules) ->
    [onsync_apply(Fun, Modules) || Fun <- Funs].

onsync_apply({M, F}, Modules) ->
    erlang:apply(M, F, [Modules]);
onsync_apply(Fun, Modules) when is_function(Fun) ->
    Fun(Modules).

get_nodes() ->
    lists:usort(lists:flatten(nodes() ++ [rpc:call(X, erlang, nodes, []) || X <- nodes()])) -- [node()].

load_module_on_all_nodes(Module) ->
    %% Get a list of nodes known by this node, plus all attached
    %% nodes.
    Nodes = get_nodes(),
    io:format("[~s:~p] DEBUG - Nodes: ~p~n", [?MODULE, ?LINE, Nodes]),
    NumNodes = length(Nodes),

    {Module, Binary, _} = code:get_object_code(Module),
    F = fun(Node) ->
        io:format("[~s:~p] DEBUG - Node: ~p~n", [?MODULE, ?LINE, Node]),
        Msg = io_lib:format("Reloading '~s' on ~s.~n", [Module, Node]),
        sync_notify:log_success(Msg),
        rpc:call(Node, code, ensure_loaded, [Module]),
        case rpc:call(Node, code, which, [Module]) of
            Filename when is_binary(Filename) orelse is_list(Filename) ->
                %% File exists, overwrite and load into VM.
                ok = rpc:call(Node, file, write_file, [Filename, Binary]),
                rpc:call(Node, code, purge, [Module]),
                {module, Module} = rpc:call(Node, code, load_file, [Module]);
            _ ->
                %% File doesn't exist, just load into VM.
                {module, Module} = rpc:call(Node, code, load_binary, [Module, undefined, Binary])
        end,
        sync_notify:growl_success("Reloaded " ++ atom_to_list(Module) ++ " on " ++ atom_to_list(Node) ++ ".")
    end,
    [F(X) || X <- Nodes],
    {ok, NumNodes}.

process_src_file_lastmod([{File, LastMod}|T1], [{File, LastMod}|T2], EnablePatching) ->
    %% Beam hasn't changed, do nothing...
    process_src_file_lastmod(T1, T2, EnablePatching);
process_src_file_lastmod([{File, _}|T1], [{File, _}|T2], EnablePatching) ->
    %% File has changed, recompile...
    recompile_src_file(File, EnablePatching),
    process_src_file_lastmod(T1, T2, EnablePatching);
process_src_file_lastmod([{File1, LastMod1}|T1], [{File2, LastMod2}|T2], EnablePatching) ->
    %% Lists are different...
    case File1 < File2 of
        true ->
            %% File was removed, do nothing...
            process_src_file_lastmod(T1, [{File2, LastMod2}|T2], EnablePatching);
        false ->
            maybe_recompile_src_file(File2, LastMod2, EnablePatching),
            process_src_file_lastmod([{File1, LastMod1}|T1], T2, EnablePatching)
    end;
process_src_file_lastmod([], [{File, LastMod}|T2], EnablePatching) ->
    maybe_recompile_src_file(File, LastMod, EnablePatching),
    process_src_file_lastmod([], T2, EnablePatching);
process_src_file_lastmod(_A, [], _) ->
    %% All remaining files, if any, were removed.
    ok;
process_src_file_lastmod(undefined, _Other, _) ->
    %% First load, do nothing.
    ok.


erlydtl_compile(SrcFile, Options) ->
    F = fun({outdir, OutDir}, Acc) -> [{out_dir, OutDir} | Acc];
           (OtherOption, Acc) -> [OtherOption | Acc]
        end,
    DtlOptions = lists:foldl(F, [], Options),
    Module =
        list_to_atom(
            lists:flatten(filename:basename(SrcFile, ".dtl") ++ "_dtl")),
    Compiler = erlydtl,
    Compiler:compile(SrcFile, Module, DtlOptions).

elixir_compile(SrcFile, Options) ->
    Outdir = proplists:get_value(outdir, Options),
    Compiler = 'Elixir.Kernel.ParallelCompiler',
    Modules = Compiler:files_to_path([list_to_binary(SrcFile)], list_to_binary(Outdir)),
    Loader = fun(Module) ->
        Outfile = code:which(Module),
        Binary = file:read_file(Outfile),
        {Module, Binary}
    end,
    Results = lists:map(Loader, Modules),
    {ok, multiple, Results, []}.

lfe_compile(SrcFile, Options) ->
    Compiler = lfe_comp,
    Compiler:file(SrcFile, Options).

maybe_recompile_src_file(File, LastMod, EnablePatching) ->
    Module = list_to_atom(filename:basename(File, ".erl")),
    file:write_file("recompile.log", ["Checking ",atom_to_list(Module),"\n"], [append]),
    case code:which(Module) of
        BeamFile when is_list(BeamFile) ->
            %% check with beam file
            case filelib:last_modified(BeamFile) of
                BeamLastMod when LastMod > BeamLastMod ->
                    recompile_src_file(File, EnablePatching);
                _ ->
                    ok
            end;
        _ ->
            %% File is new, recompile...
            recompile_src_file(File, EnablePatching)
    end.

determine_compile_fun_and_module_name(SrcFile) ->
    case sync_utils:get_filetype(SrcFile) of
        erl ->
            {fun compile:file/2,
            list_to_atom(filename:basename(SrcFile, ".erl"))};
        dtl ->
            {fun erlydtl_compile/2,
            list_to_atom(lists:flatten(filename:basename(SrcFile, ".dtl") ++ "_dtl"))};
        lfe ->
            {fun lfe_compile/2,
            list_to_atom(filename:basename(SrcFile, ".lfe"))};
        elixir ->
            {fun elixir_compile/2,
            list_to_atom(filename:basename(SrcFile, ".ex"))}
     end.

get_object_code(Module) ->
    case code:get_object_code(Module) of
        {Module, B, _Filename} -> B;
        _ -> undefined
    end.

reload_if_necessary(_CompileFun, SrcFile, Module, Binary, Binary, _Options, Warnings) ->
    %% Compiling didn't change the beam code. Don't reload...
    print_results(Module, SrcFile, [], Warnings),
    {ok, [], Warnings};

reload_if_necessary(CompileFun, SrcFile, Module, _OldBinary, _Binary, Options, Warnings) ->
    %% Compiling changed the beam code. Compile and reload.
    case CompileFun(SrcFile, [return | Options]) of
        {ok, _} ->
            ok;
        {ok, _, _} ->
            ok;
        CompileResult ->
            sync_notify:log_warnings("Compile failed in reload_if_necessary(): ~p~n",
                                     [CompileResult])
    end,
    %% Try to load the module...
    case code:ensure_loaded(Module) of
        {module, Module} -> ok;
        {error, nofile} -> error_no_file(Module);
        {error, embedded} ->
            %% Module is not yet loaded, load it.
            case code:load_file(Module) of
                {module, Module} -> ok;
                {error, nofile} ->
                    error_no_file(Module)
            end
    end,
    gen_server:cast(?SERVER, compare_beams),

    %% Print the warnings...
    print_results(Module, SrcFile, [], Warnings),
    {ok, [], Warnings}.

error_no_file(Module) ->
    Msg = io_lib:format("~p Couldn't load module: nofile~n", [Module]),
    sync_notify:log_warnings([Msg]).

recompile_src_file(SrcFile, _EnablePatching) ->
    file:write_file("recompile.log", [SrcFile, "\n"], [append]),
    %% Get the module, src dir, and options...
    {ok, SrcDir} = sync_utils:get_src_dir(SrcFile),
    {CompileFun, Module} = determine_compile_fun_and_module_name(SrcFile),

    %% Get the old binary code...
    OldBinary = get_object_code(Module),

    case sync_options:get_options(SrcDir) of
        {ok, Options0} ->
            %% Event messages from fs may disrupt compile module, spawn it
            Options = lists:delete(no_spawn_compiler_process, Options0),
            case CompileFun(SrcFile, [binary, return|Options]) of
                {ok, Module, Binary, Warnings} ->
                    reload_if_necessary(CompileFun, SrcFile, Module, OldBinary, Binary, Options, Warnings);

                {ok, [{ok, Module, Binary, Warnings}], Warnings2} ->
                    reload_if_necessary(CompileFun, SrcFile, Module, OldBinary, Binary, Options, Warnings ++ Warnings2);

                {ok, multiple, Results, Warnings} ->
                    Reloader = fun({CompiledModule, Binary}) ->
                        {ok, _, _} = reload_if_necessary(CompileFun, SrcFile, CompiledModule, OldBinary, Binary, Options, Warnings)
                    end,
                    lists:foreach(Reloader, Results),
                    {ok, [], Warnings};

                {ok, OtherModule, _Binary, Warnings} ->
                    Desc = io_lib:format("Module definition (~p) differs from expected (~s)", [OtherModule, filename:rootname(filename:basename(SrcFile))]),
                
                    Errors = [{SrcFile, {0, Module, Desc}}],
                    print_results(Module, SrcFile, Errors, Warnings),
                    {ok, Errors, Warnings};
    
                {error, Errors, Warnings} ->
                    %% Compiling failed. Print the warnings and errors...
                    print_results(Module, SrcFile, Errors, Warnings),
                    {ok, Errors, Warnings}
            end;

        undefined ->
            Msg = io_lib:format("Unable to determine options for ~p", [SrcFile]),
            sync_notify:log_errors(Msg)
    end.


print_results(Module, SrcFile, [], []) ->
    Msg = io_lib:format("~s: Recompiled.~n", [SrcFile]),
    case code:is_loaded(Module) of
        {file, _} ->
            ok;
        false ->
            sync_notify:growl_success("Recompiled " ++ SrcFile ++ ".")
    end,
    sync_notify:log_success(lists:flatten(Msg));

print_results(_Module, SrcFile, [], Warnings) ->
    Msg = [
        format_errors(SrcFile, [], Warnings),
        io_lib:format("~s Recompiled with ~p warnings~n", [SrcFile, length(Warnings)])
    ],
    sync_notify:growl_warnings(growl_format_errors([], Warnings)),
    sync_notify:log_warnings(Msg);

print_results(_Module, SrcFile, Errors, Warnings) ->
    Msg = [
        format_errors(SrcFile, Errors, Warnings)
    ],
    sync_notify:growl_errors(growl_format_errors(Errors, Warnings)),
    sync_notify:log_errors(Msg).


%% @private Print error messages in a pretty and user readable way.
format_errors(File, Errors, Warnings) ->
    AllErrors1 = lists:sort(lists:flatten([X || {_, X} <- Errors])),
    AllErrors2 = [{Line, "Error", Module, Description} || {Line, Module, Description} <- AllErrors1],
    AllWarnings1 = lists:sort(lists:flatten([X || {_, X} <- Warnings])),
    AllWarnings2 = [{Line, "Warning", Module, Description} || {Line, Module, Description} <- AllWarnings1],
    Everything = lists:sort(AllErrors2 ++ AllWarnings2),
    F = fun({Line0, Prefix, Module, ErrorDescription}) ->
        Msg = format_error(Module, ErrorDescription),
        Line = format_line(Line0),
        io_lib:format("~s ~s: ~s: ~s~n", [File, Line, Prefix, Msg])
    end,
    [F(X) || X <- Everything].

format_error(Module, ErrorDescription) ->
    case erlang:function_exported(Module, format_error, 1) of
        true -> Module:format_error(ErrorDescription);
        false -> io_lib:format("~s", [ErrorDescription])
    end.

%% @private Print error messages in a pretty and user readable way.
growl_format_errors(Errors, Warnings) ->
    AllErrors1 = lists:sort(lists:flatten([X || {_, X} <- Errors])),
    AllErrors2 = [{Line, "Error", Module, Description} || {Line, Module, Description} <- AllErrors1],
    AllWarnings1 = lists:sort(lists:flatten([X || {_, X} <- Warnings])),
    AllWarnings2 = [{Line, "Warning", Module, Description} || {Line, Module, Description} <- AllWarnings1],
    Everything = lists:sort(AllErrors2 ++ AllWarnings2),
    F = fun({Line0, Prefix, Module, ErrorDescription}) ->
        Line = format_line(Line0),
        Msg = format_error(Module, ErrorDescription),
        io_lib:format("~s: ~s: ~s~n", [Line, Prefix, Msg])
    end,
    [F(X) || X <- Everything].

format_line(Line) when is_integer(Line) ->
    "(Line " ++ integer_to_list(Line) ++ ")";
format_line({Line, Char}) ->
    "(Line " ++ integer_to_list(Line) ++ ", Char " ++ integer_to_list(Char) ++ ")";
format_line(Other)->
    io_lib:format("(Line: ~p)", [Other]).

process_hrl_file_lastmod(Files1, Files2, SrcFiles, Patching, Method) ->
    SrcFileMaybeHeaders = case Method of
        init -> pre_get_includes(SrcFiles);
        _ -> SrcFiles
    end,
    NewFiles = inner_process_hrl_file_lastmod(Files1, Files2, SrcFileMaybeHeaders),
    UniqueFiles = dedup_modules(NewFiles),
    lists:foreach(fun({SrcFile, LastMod}) ->
        maybe_recompile_src_file(SrcFile, LastMod, Patching)
    end, UniqueFiles).


dedup_modules(ModulesWithModTimes) ->
    Map = lists:foldl(fun({Module, LastMod}, Acc) ->
        case maps:find(Module, Acc) of
            error -> maps:put(Module, LastMod, Acc);
            {ok, ThisMod} when LastMod > ThisMod -> maps:put(Module, LastMod, Acc);
            _ -> Acc
        end
    end, #{}, ModulesWithModTimes),
    maps:to_list(Map).

inner_process_hrl_file_lastmod([{File, LastMod}|T1], [{File, LastMod}|T2], SrcFileHeaders) ->
    %% Hrl hasn't changed, do nothing...
    inner_process_hrl_file_lastmod(T1, T2, SrcFileHeaders);
inner_process_hrl_file_lastmod([{File, LastMod1}|T1], [{File, LastMod2}|T2], SrcFileHeaders) ->
    %% File has changed, recompile...
    LastMod = lists:max([LastMod1, LastMod2]),
    WhoInclude = [{Module, LastMod} || Module <- who_include(File, SrcFileHeaders)],
    WhoInclude ++ inner_process_hrl_file_lastmod(T1, T2, SrcFileHeaders);
inner_process_hrl_file_lastmod([{File1, LastMod1}|T1], [{File2, LastMod2}|T2], SrcFileHeaders) ->
    %% Lists are different...
    case File1 < File2 of
        true ->
            %% File was removed, do nothing...
            warn_deleted_hrl_files(File1, SrcFileHeaders),
            inner_process_hrl_file_lastmod(T1, [{File2, LastMod2}|T2], SrcFileHeaders);
        false ->
            %% File is new, look for src that include it
            WhoInclude = [{Module, LastMod2} || Module <- who_include(File2, SrcFileHeaders)],
            WhoInclude ++ inner_process_hrl_file_lastmod([{File1, LastMod1}|T1], T2, SrcFileHeaders)
    end;
inner_process_hrl_file_lastmod([], [{File, LastMod}|T2], SrcFileHeaders) ->
    %% File is new, look for src that include it
    WhoInclude = [{Module, LastMod} || Module <- who_include(File, SrcFileHeaders)],
    WhoInclude ++ inner_process_hrl_file_lastmod([], T2, SrcFileHeaders);
inner_process_hrl_file_lastmod([{File1, _LastMod1}|T1], [], SrcFileHeaders) ->
    %% Rest of file(s) removed, warn and process next
    warn_deleted_hrl_files(File1, SrcFileHeaders),
    inner_process_hrl_file_lastmod(T1, [], SrcFileHeaders);
inner_process_hrl_file_lastmod([], [], _) ->
    %% Done
    [];
inner_process_hrl_file_lastmod(undefined, _Other, _) ->
    %% First load, do nothing
    [].

warn_deleted_hrl_files(HrlFile, SrcFileHeaders) ->
    WhoInclude = who_include(HrlFile, SrcFileHeaders),
    case WhoInclude of
        [] -> ok;
        _ -> io:format(
                "Warning. Deleted ~p file included in existing src files: ~p~n",
                [filename:basename(HrlFile), lists:map(fun(File) -> filename:basename(File) end, WhoInclude)])
    end.

pre_get_includes(SrcFiles) ->
    lists:map(fun(SrcFile) ->
        {ok, Forms} = epp_dodger:parse_file(SrcFile),
        Includes = extract_include(Forms),
        {SrcFile, Includes}
    end, SrcFiles).
    

who_include(HrlFile, SrcFilesMaybeWithHeaders) ->
    HrlFileBaseName = filename:basename(HrlFile),
    Pred = fun
        ({SrcFile, Headers}) ->
            case lists:member(HrlFileBaseName, Headers) of
                true -> {true, SrcFile};
                false -> false
            end;
        (SrcFile) ->
            {ok, Forms} = epp_dodger:parse_file(SrcFile),
            is_include(HrlFileBaseName, Forms)
    end,
    lists:filtermap(Pred, SrcFilesMaybeWithHeaders).

extract_include([]) ->
    [];
extract_include([{tree, attribute, _, {attribute, _, [{_, _, IncludeFile}]}} | Forms]) when is_list(IncludeFile) ->
    IncludeFileBaseName = filename:basename(IncludeFile),
    [IncludeFileBaseName | extract_include(Forms)];
extract_include([_|Forms]) ->
    extract_include(Forms).

is_include(_HrlFile, []) ->
    false;
is_include(HrlFile, [{tree, attribute, _, {attribute, _, [{_, _, IncludeFile}]}} | Forms]) when is_list(IncludeFile) ->
    IncludeFileBaseName = filename:basename(IncludeFile),
    case IncludeFileBaseName of
        HrlFile -> true;
        _ -> is_include(HrlFile, Forms)
    end;
is_include(HrlFile, [_SomeForm | Forms]) ->
    is_include(HrlFile, Forms).

%% @private Filter the modules to be scanned.
filter_modules_to_scan(Modules) ->
    Whitelist = sync_utils:whitelisted_modules(),
    Exclude = sync_utils:excluded_modules(),
    filter_modules(Modules, Whitelist, Exclude).
    

filter_modules(Modules, Whitelist, Exclude) ->
    lists:filter(fun(Module) ->
        Whitelisted = module_matches(Module, Whitelist),
        Excluded = module_matches(Module, Exclude),

        Whitelisted orelse not(Excluded)
    end, Modules).
    

module_matches(_Module, []) ->
    false;
module_matches(Module, [Module2|T]) when is_atom(Module2) ->
    case Module =:= Module2 of
        true -> true;
        false -> module_matches(Module, T)
    end;
module_matches(Module, [Pattern|T]) when is_list(Pattern) ->
    case re:run(atom_to_list(Module), Pattern) of
        {match, _} -> true;
        nomatch -> module_matches(Module, T)
    end.


discover_source_dirs(State, ExtraDirs, ReplaceDirs) ->
    %% Extract the compile / options / source / dir from each module.
    F = fun
        (X, Acc = {SrcAcc, HrlAcc}) ->
            %% Get the dir...
            case sync_utils:get_src_dir_from_module(X) of
                {ok, SrcDir} ->
                    case is_replace_dir(SrcDir, ReplaceDirs) of
                        true ->
                            %% Get the options, store under the dir...
                            {ok, Options} = sync_utils:get_options_from_module(X),
                            %% Store the options for later reference...
                            HrlDir = proplists:get_all_values(i, Options),

                            sync_options:set_options(SrcDir, Options),
                            %% Return the dir...
                            {[SrcDir|SrcAcc], HrlDir ++ HrlAcc};
                        _ ->
                            Acc
                    end;
                undefined ->
                    Acc
            end
    end,
    {SrcDirs, HrlDirs} = lists:foldl(F, {ExtraDirs, []}, State#state.modules),
    USortedSrcDirs = lists:usort(SrcDirs),
    USortedHrlDirs = lists:usort(HrlDirs),
    %% InitialDirs = sync_utils:initial_src_dirs(),

    %% Schedule the next interval...
    case State#state.sync_method of
        scanner ->
            NewTimers = schedule_cast(discover_src_dirs, 30000, State#state.timers),

            %% Return with updated dirs...
            NewState = State#state { src_dirs=USortedSrcDirs, hrl_dirs=USortedHrlDirs, timers=NewTimers },
            {noreply, NewState};
        fsevents ->
            %% Stop old processes
            start_fsevents(SrcDirs++HrlDirs, ReplaceDirs, State#state{
                src_dirs = USortedSrcDirs,
                hrl_dirs = USortedHrlDirs
            })
    end.

start_fsevents(MonitorDirs, ReplaceDirs, State) ->
    %% Stop existing fs processes if any
    [erlang:exit(Pid, normal) || Pid <- State#state.fsevents_pids],

    %% Start new fs processes based on the user inputs
    NewPids = lists:foldl(fun
        (Dir, Acc) ->
            Name = erlang:list_to_atom(Dir),
            case file:read_link_info(Dir) of
                {ok, #file_info{type = symlink}} ->
                    Acc;
                {ok, _} ->
                    case fs:start_link(Name, Dir) of
                        {ok, Pid} ->
                            fs:subscribe(Name),
                            [Pid | Acc];
                        _ ->
                            Acc
                    end;
                _ ->
                    Acc
            end
    end, [], MonitorDirs),

    %% It is possible that not all modules are discovered
    %% by the time this process is ran. So, handle that
    DirsNotDiscovered = lists:foldl(fun
        (_, []) ->
            [];
        (Dir, Acc) ->
            lists:filter(fun
                (Match) ->
                    string:split(Dir, Match) == [Dir]
            end, Acc)
    end, ReplaceDirs, MonitorDirs),

    %% Restart the discovery process if needed ...
    NewTimers = case DirsNotDiscovered == [] of
        true ->
             proplists:delete(discover_src_dirs, State#state.timers);
        _ ->
            T1 = schedule_cast(discover_modules, 3000, State#state.timers),
            T2 = schedule_cast(discover_src_dirs, 4000, T1),
            schedule_cast(discover_src_files, 5000, T2)
    end,

    gen_server:cast(?SERVER, compare_beams),
    {noreply, State#state{
        fsevents_pids = NewPids,
        timers = NewTimers
    }}.

is_replace_dir(_, []) ->
    true;
is_replace_dir(SrcDir, ReplaceDirs) ->
    lists:foldl(fun
        (Dir, false) ->
            case re:run(SrcDir, Dir) of nomatch -> false; _ -> true end;
        (_, Acc) -> Acc
    end, false, ReplaceDirs).

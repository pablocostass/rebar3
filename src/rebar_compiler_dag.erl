%%% Module handling the directed graph required for the analysis
%%% of all top-level applications by the various compiler plugins.
-module(rebar_compiler_dag).
-export([init/4, maybe_store/5, terminate/1]).
-export([prune/5, populate_sources/5, populate_deps/3, propagate_stamps/1,
         compile_order/2, store_artifact/4]).

-include("rebar.hrl").

-define(DAG_VSN, 4).
-define(DAG_ROOT, "source").
-define(DAG_EXT, ".dag").

-type critical_meta() :: term().

-record(dag, {vsn = ?DAG_VSN :: pos_integer(),
    meta :: critical_meta(),
    vtab :: notable | [tuple()],
    etab :: notable | [tuple()],
    ntab :: notable | [tuple()]}).

-type dag() :: digraph:graph().

%% @doc You should initialize one DAG per compiler module.
%% `CritMeta' is any contextual information that, if it is found to change,
%% must invalidate the DAG loaded from disk.
-spec init(file:filename_all(), atom(), string() | undefined, critical_meta()) -> dag().
init(Dir, Compiler, Label, CritMeta) ->
    G = digraph:new([acyclic]),
    File = dag_file(Dir, Compiler, Label),
    try
        restore_dag(G, File, CritMeta)
    catch
        _:_ ->
            %% Don't mark as dirty yet to avoid creating compiler DAG files for
            %% compilers that are actually never used.
            ?WARN("Failed to restore ~ts file. Discarding it.~n", [File]),
            file:delete(File)
    end,
    G.

%% @doc Clear up inactive (deleted) source files from a given project.
%% The file must be in one of the directories that may contain source files
%% for an OTP application; source files found in the DAG `G' that lie outside
%% of these directories may be used in other circumstances (i.e. options affecting
%% visibility, extra_src_dirs).
%% Prune out files that have no corresponding sources
prune(G, SrcExt, ArtifactExt, Sources, AppPaths) ->
    %% Collect source files that may have been removed. These files:
    %%  * are not in Sources
    %%  * have SrcExt
    %% In the process, prune header files - those don't have ArtifactExt
    %%  extension - using side effect in is_deleted_source/5.
    case [Del || Del <- (digraph:vertices(G) -- Sources),
          is_deleted_source(G, Del, filename:extension(Del), SrcExt, ArtifactExt)] of
        [] ->
            ok; %% short circuit without sorting AppPaths
        Deleted ->
            SafeAppPaths = safe_dirs(AppPaths),
            OutFiles = filter_prefix(G, lists:sort(SafeAppPaths), lists:sort(Deleted)),
            [maybe_rm_artifact_and_edge(G, Out, SrcExt, ArtifactExt, File)
             || {File, Out} <- OutFiles],
            ok
    end.

%% Some app paths may be prefixes of one another; for example,
%% `/some/app/directory' may be seen as a prefix
%% of `/some/app/directory_trick' and cause pruning outside
%% of the proper scopes.
safe_dirs(AppPaths) ->
    [{safe_dir(AppDir), Path} || {AppDir, Path} <- AppPaths].

safe_dir([]) -> "/";
safe_dir("/") -> "/";
safe_dir([H|T]) -> [H|safe_dir(T)].

is_deleted_source(_G, _F, Extension, Extension, _ArtifactExt) ->
    %% source file
    true;
is_deleted_source(_G, _F, Extension, _SrcExt, Extension) ->
    %% artifact file - skip
    false;
is_deleted_source(G, F, _Extension, _SrcExt, _ArtifactExt) ->
    %% must be header file or artifact
    digraph:in_edges(G, F) == [] andalso maybe_rm_vertex(G, F),
    false.

%% This can be implemented using smarter trie, but since the
%%  whole procedure is rare, don't bother with optimisations.
%% AppDirs & Fs are sorted, and to check if File is outside of
%%  App, lists:prefix is checked. When the App with File in it
%%  exists, verify file is still there on disk.
filter_prefix(_G, [], _) ->
    [];
filter_prefix(_G, _, []) ->
    [];
filter_prefix(G, Apps, [F|Fs]) when is_atom(F) ->
    %% dirty bit shenanigans
    filter_prefix(G, Apps, Fs);
filter_prefix(G, [{App, Out} | AppTail] = AppPaths, [File | FTail]) ->
    case lists:prefix(App, File) of
        true ->
            [{File, Out} | filter_prefix(G, AppPaths, FTail)];
        false when App < File ->
            filter_prefix(G, AppTail, [File|FTail]);
        false ->
            filter_prefix(G, AppPaths, FTail)
    end.

finalise_populate_sources(_G, _InDirs, Waiting) when Waiting =:= #{} ->
    ok;
finalise_populate_sources(G, InDirs, Waiting) ->
    %% wait for all deps to complete
    receive
        {deps, Pid, AbsIncls} ->
            {Status, Source} = maps:get(Pid, Waiting),
            %% the file hasn't been visited yet; set it to existing, but with
            %% a last modified value that's null so it gets updated to something new.
            [digraph:add_vertex(G, Src, 0) || Src <- AbsIncls,
                digraph:vertex(G, Src) =:= false],
            %% drop edges from deps that aren't included!
            [digraph:del_edge(G, Edge) || Status == old,
                Edge <- digraph:out_edges(G, Source),
                {_, _Src, Path, _Label} <- [digraph:edge(G, Edge)],
                not lists:member(Path, AbsIncls)],
            %% Add the rest
            [digraph:add_edge(G, Source, Incl) || Incl <- AbsIncls],
            %% mark the digraph dirty when there is any change in
            %%  dependencies, for any application in the project
            mark_dirty(G),
            finalise_populate_sources(G, InDirs, Waiting);
        {'DOWN', _MRef, process, Pid, normal} ->
            finalise_populate_sources(G, InDirs, maps:remove(Pid, Waiting));
        {'DOWN', _MRef, process, Pid, Reason} ->
            {_Status, Source} = maps:get(Pid, Waiting),
            ?ERROR("Failed to get dependencies for ~s~n~p", [Source, Reason]),
            ?ABORT
    end.

%% @doc this function scans all the source files found and looks into
%% all the `InDirs' for deps (other source files, or files that aren't source
%% but still returned by the compiler module) that are related
%% to them.
populate_sources(G, Compiler, InDirs, Sources, DepOpts) ->
    populate_sources(G, Compiler, InDirs, Sources, DepOpts, #{}).

populate_sources(G, _Compiler, InDirs, [], _DepOpts, Waiting) ->
    finalise_populate_sources(G, InDirs, Waiting);
populate_sources(G, Compiler, InDirs, [Source|Erls], DepOpts, Waiting) ->
    case digraph:vertex(G, Source) of
        {_, LastUpdated} ->
            case filelib:last_modified(Source) of
                0 ->
                    %% The File doesn't exist anymore, delete
                    %% from the graph.
                    digraph:del_vertex(G, Source),
                    mark_dirty(G),
                    populate_sources(G, Compiler, InDirs, Erls, DepOpts, Waiting);
                LastModified when LastUpdated < LastModified ->
                    digraph:add_vertex(G, Source, LastModified),
                    Worker = prepopulate_deps(Compiler, InDirs, Source, DepOpts, self()),
                    populate_sources(G, Compiler, InDirs, Erls, DepOpts, Waiting#{Worker => {old, Source}});
                _ -> % unchanged
                    populate_sources(G, Compiler, InDirs, Erls, DepOpts, Waiting)
            end;
        false ->
            LastModified = filelib:last_modified(Source),
            digraph:add_vertex(G, Source, LastModified),
            Worker = prepopulate_deps(Compiler, InDirs, Source, DepOpts, self()),
            populate_sources(G, Compiler, InDirs, Erls, DepOpts, Waiting#{Worker => {new, Source}})
    end.

%% @doc Scan all files in the digraph that are seen as dependencies, but are
%% neither source files nor artifacts (i.e. header files that don't produce
%% artifacts of any kind).
populate_deps(G, SourceExt, ArtifactExts) ->
    %% deps are files that are part of the digraph, but couldn't be scanned
    %% because they are neither source files (`SourceExt') nor mappings
    %% towards build artifacts (`ArtifactExts'); they will therefore never
    %% be handled otherwise and need to be re-scanned for accuracy, even
    %% if they are not being analyzed (we assume `Compiler:deps' did that
    %% in depth already, and improvements should be driven at that level)
    IgnoredExts = [SourceExt | ArtifactExts],
    Vertices = digraph:vertices(G),
    [refresh_dep(G, digraph:vertex(G, File))
     || File <- Vertices,
        Ext <- [filename:extension(File)],
        not lists:member(Ext, IgnoredExts)],
    ok.


%% @doc Take the timestamps/diff changes and propagate them from a dep to the
%% parent; given:
%%   A 0 -> B 1 -> C 3 -> D 2
%% then we expect to get back:
%%   A 3 -> B 3 -> C 3 -> D 2
%% This is going to be safe for the current run of regeneration, but also for the
%% next one; unless any file in the chain has changed, the stamp won't move up
%% and there won't be a reason to recompile.
%% The obvious caveat to this one is that a file changing by restoring an old version
%% won't be picked up, but this weakness already existed in terms of timestamps.
propagate_stamps(G) ->
    case is_dirty(G) of
        false ->
            %% no change, no propagation to make
            ok;
        true ->
            %% we can use a topsort, start at the end of it (files with no deps)
            %% and update them all in order. By doing this, each file only needs to check
            %% for one level of out-neighbours to set itself to the right appropriate time.
            DepSort = lists:reverse(digraph_utils:topsort(G)),
            propagate_stamps(G, DepSort)
    end.


%% @doc Return the reverse sorting order to get dep-free apps first.
%% -- we would usually not need to consider the non-source files for the order to
%% be complete, but using them doesn't hurt.
compile_order(_, AppDefs) when length(AppDefs) =< 1 ->
    [Name || {Name, _Path} <- AppDefs];
compile_order(G, AppDefs) ->
    Edges = [{V1,V2} || E <- digraph:edges(G),
                        {_,V1,V2,_} <- [digraph:edge(G, E)]],
    AppPaths = prepare_app_paths(AppDefs),
    compile_order(Edges, AppPaths, #{}).

%% @doc Store the DAG on disk if it was dirty
maybe_store(G, Dir, Compiler, Label, CritMeta) ->
    case is_dirty(G) of
        true ->
            clear_dirty(G),
            File = dag_file(Dir, Compiler, Label),
            store_dag(G, File, CritMeta);
        false ->
            ok
    end.

%% Get rid of the live state for the digraph; leave disk stuff in place.
terminate(G) ->
    true = digraph:delete(G).

store_artifact(G, Source, Target, Meta) ->
    digraph:add_vertex(G, Target, {artifact, Meta}),
    digraph:add_edge(G, Target, Source, artifact).

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
%% @private generate the name for the DAG based on the compiler module and
%% a custom label, both of which are used to prevent various compiler runs
%% from clobbering each other. The label `undefined' is kept for a default
%% run of the compiler, to keep in line with previous versions of the file.
dag_file(Dir, CompilerMod, undefined) ->
    filename:join([rebar_dir:local_cache_dir(Dir), CompilerMod,
                   ?DAG_ROOT ++ ?DAG_EXT]);
dag_file(Dir, CompilerMod, Label) ->
    filename:join([rebar_dir:local_cache_dir(Dir), CompilerMod,
                   ?DAG_ROOT ++ "_" ++ Label ++ ?DAG_EXT]).

restore_dag(G, File, CritMeta) ->
    case file:read_file(File) of
        {ok, Data} ->
            %% The CritMeta value is checked and if it doesn't match, we fail
            %% the whole restore operation.
            #dag{vsn=?DAG_VSN, meta = CritMeta, vtab = VTab,
                etab = ETab, ntab = NTab} = binary_to_term(Data),
            {digraph, VT, ET, NT, false} = G,
            true = ets:insert_new(VT, VTab),
            true = ets:insert_new(ET, ETab),
            true = ets:delete_all_objects(NT),
            true = ets:insert(NT, NTab),
            ok;
        {error, _Err} ->
            ok
    end.

store_dag(G, File, CritMeta) ->
    ok = filelib:ensure_dir(File),
    {digraph, VT, ET, NT, false} = G,
    Data = term_to_binary(#dag{meta = CritMeta, vtab = ets:tab2list(VT),
        etab = ets:tab2list(ET), ntab = ets:select(NT, [{'_',[],['$_']}])}, [{compressed, 2}]),
    file:write_file(File, Data).

%% Drop a file from the digraph if it doesn't exist, and if so,
%% delete its related build artifact
maybe_rm_artifact_and_edge(G, OutDir, SrcExt, Ext, Source) ->
    %% This is NOT a double check it is the only check that the source file is actually gone
    case filelib:is_regular(Source) of
        true ->
            %% Actually exists, don't delete
            false;
        false ->
            Edges = digraph:in_edges(G, Source),
            Targets = [V1 || Edge <- Edges,
                             {_E, V1, _V2, artifact} <- [digraph:edge(G, Edge)]],
            case Targets of
                [] ->
                    Target = target(OutDir, Source, SrcExt, Ext),
                    ?DEBUG("Source ~ts is gone, deleting previous ~ts file if it exists ~ts", [Source, Ext, Target]),
                    file:delete(Target);
                [_|_] ->
                    lists:foreach(fun(Target) ->
                        ?DEBUG("Source ~ts is gone, deleting artifact ~ts "
                                "if it exists", [Source, Target]),
                        file:delete(Target)
                    end, Targets)
            end,
            digraph:del_vertex(G, Source),
            mark_dirty(G),
            true
    end.

maybe_rm_vertex(G, Source) ->
    case filelib:is_regular(Source) of
        true ->
            exists;
        false ->
            digraph:del_vertex(G, Source),
            mark_dirty(G)
    end.

%% Add dependencies of a given file to the DAG. If the file is not found yet,
%% mark its timestamp to 0, which means we have no info on it.
%% Source files will be covered at a later point in their own scan, and
%% non-source files are going to be covered by `populate_deps/3'.
prepopulate_deps(Compiler, InDirs, Source, DepOpts, Control) ->
    {Worker, _MRef} = spawn_monitor(
        fun () ->
            SourceDir = filename:dirname(Source),
            AbsIncls = case erlang:function_exported(Compiler, dependencies, 4) of
                false ->
                    Compiler:dependencies(Source, SourceDir, InDirs);
                true ->
                    Compiler:dependencies(Source, SourceDir, InDirs, DepOpts)
            end,
            Control ! {deps, self(), AbsIncls}
        end
    ),
    Worker.

%% check that a dep file is up to date
refresh_dep(_G, {artifact, _}) ->
    %% ignore artifacts
    ok;
refresh_dep(G, {File, LastUpdated}) ->
    case filelib:last_modified(File) of
        0 ->
            %% Gone! Erase from the graph
            digraph:del_vertex(G, File),
            mark_dirty(G);
        LastModified when LastUpdated < LastModified ->
            digraph:add_vertex(G, File, LastModified),
            mark_dirty(G);
        _ ->
            %% unchanged
            ok
    end.

%% Do the actual propagation of all files; the files are expected to be
%% in a topological order such that we don't need to go more than a level
%% deep in what we search.
propagate_stamps(_G, []) ->
    ok;
propagate_stamps(G, [File|Files]) ->
    Stamps = [Stamp
              || F <- digraph:out_neighbours(G, File),
                 {_, Stamp} <- [digraph:vertex(G, F)],
                 is_tuple(Stamp) andalso element(1, Stamp) =/= artifact],
    case Stamps of
        [] ->
            ok;
        _ ->
            Max = lists:max(Stamps),
            case digraph:vertex(G, File) of
                {_, {artifact, _}} ->
                    ok;
                {_, Smaller} when Smaller < Max ->
                    digraph:add_vertex(G, File, Max);
                _ ->
                    ok
            end
    end,
    propagate_stamps(G, Files).

%% Do the actual reversal; be aware that only working from the edges
%% may omit files, so we have to add all non-dependant apps manually
%% to make sure we don't drop em. Since they have no deps, they're
%% safer to put first (and compile first)
compile_order([], AppPaths, AppDeps) ->
    %% use a digraph so we don't reimplement topsort by hand.
    G = digraph:new([acyclic]), % ignore cycles and hope it works
    Tups = maps:keys(AppDeps),
    {Va,Vb} = lists:unzip(Tups),
    [digraph:add_vertex(G, V) || V <- Va],
    [digraph:add_vertex(G, V) || V <- Vb],
    [digraph:add_edge(G, V1, V2) || {V1, V2} <- Tups],
    Sorted = lists:reverse(digraph_utils:topsort(G)),
    digraph:delete(G),
    Standalone = [Name || {_, Name} <- AppPaths] -- Sorted,
    Standalone ++ Sorted;
compile_order([{P1,P2}|T], AppPaths, AppDeps) ->
    %% Assume most dependencies are between files of the same app
    %% so ask to see if it's the same before doing a deeper check:
    case find_app(P1, AppPaths) of
        not_found -> % system lib probably! not in the repo
            compile_order(T, AppPaths, AppDeps);
        {P1App, P1Path} ->
            case find_cached_app(P2, {P1App, P1Path}, AppPaths) of
                {P2App, _} when P2App =/= P1App ->
                    compile_order(T, AppPaths, AppDeps#{{P1App,P2App} => true});
                _ ->
                    compile_order(T, AppPaths, AppDeps)
            end
    end.

%% Swap app name with paths in the order, and sort there; this lets us
%% bail out early in a search where a file won't be found.
prepare_app_paths(AppPaths) ->
    lists:sort([{filename:split(Path), Name} || {Name, Path} <- AppPaths]).

%% Look for the app to which the path belongs; needed to
%% go from an edge between files in the DAG to building
%% app-related orderings
find_app(Path, AppPaths) ->
    find_app_(filename:split(Path), AppPaths).

%% A cached search for the app to which a path belongs;
%% the assumption is that sorted edges and common relationships
%% are going to be between local files within an app most
%% of the time; so we first look for the same path as a
%% prior match to avoid searching _all_ potential candidates.
%% If it doesn't work, go for the normal search.
find_cached_app(Path, {Name, AppPath}, AppPaths) ->
    Split = filename:split(Path),
    case find_app_(Split, [{AppPath, Name}]) of
        not_found -> find_app_(Split, AppPaths);
        LastEntry -> LastEntry
    end.

%% Do the actual recursive search
find_app_(_Path, []) ->
    not_found;
find_app_(Path, [{AppPath, AppName}|Rest]) ->
    case lists:prefix(AppPath, Path) of
        true ->
            {AppName, AppPath};
        false when AppPath > Path ->
            not_found;
        false ->
            find_app_(Path, Rest)
    end.

%% @private Return what should be the base name of an erl file, relocated to the
%% target directory. For example:
%% target_base("ebin/", "src/my_module.erl", ".erl", ".beam") -> "ebin/my_module.beam"
target(OutDir, Source, SrcExt, Ext) ->
    filename:join(OutDir, filename:basename(Source, SrcExt) ++ Ext).

%% Mark the digraph as having been modified, which is required to
%% save its updated form on disk after the compiling run.
%% This uses a magic vertex to carry the dirty state. This is less
%% than ideal because listing vertices may expect filenames and
%% instead there's going to be one trick atom through it.
mark_dirty(G) ->
    digraph:add_vertex(G, '$r3_dirty_bit', true),
    ok.

%% Check whether the digraph has been modified and is considered dirty.
is_dirty(G) ->
    case digraph:vertex(G, '$r3_dirty_bit') of
        {_, Bool} -> Bool;
        false -> false
    end.

%% Remove the dirty status. Because the saving of a digraph on disk saves all
%% vertices, clear the flag before serializing it.
clear_dirty(G) ->
    digraph:del_vertex(G, '$r3_dirty_bit').

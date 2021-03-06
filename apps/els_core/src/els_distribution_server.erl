%%%=============================================================================
%%% @doc The distribution gen_server.
%%% @end
%%%=============================================================================

-module(els_distribution_server).

%%==============================================================================
%% API
%%==============================================================================
-export([ start_link/0
        , start_distribution/1
        , connect/0
        , wait_connect_and_monitor/1
        , wait_connect_and_monitor/2
        , rpc_call/3
        , rpc_call/4
        , node_name/2
        ]).

%%==============================================================================
%% Callbacks for the gen_server behaviour
%%==============================================================================
-behaviour(gen_server).
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        ]).

%%==============================================================================
%% Includes
%%==============================================================================
-include_lib("kernel/include/logger.hrl").

%%==============================================================================
%% Type Definitions
%%==============================================================================
-type state() :: #{}.

%%==============================================================================
%% Macro Definitions
%%==============================================================================
-define(SERVER, ?MODULE).
-define(RPC_TIMEOUT, 5000).
-define(WAIT_ATTEMPTS, 30).
-define(WAIT_INTERVAL, 1000).

%%==============================================================================
%% API
%%==============================================================================
-spec start_link() -> {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, unused, []).

%% @doc Turns a non-distributed node into a distributed one
-spec start_distribution(atom()) -> ok.
start_distribution(Name) ->
  NameType = els_config_runtime:get_name_type(),
  ?LOG_INFO("Enable distribution [name=~p]", [Name]),
  case net_kernel:start([Name, NameType]) of
    {ok, _Pid} ->
      Cookie = els_config_runtime:get_cookie(),
      RemoteNode = els_config_runtime:get_node_name(),
      erlang:set_cookie(RemoteNode, Cookie),
      ?LOG_INFO("Distribution enabled [name=~p]", [Name]);
    {error, {already_started, _Pid}} ->
      ?LOG_INFO("Distribution already enabled [name=~p]", [Name]);
    {error, {{shutdown, {failed_to_start_child, net_kernel, E1}}, E2}} ->
      ?LOG_INFO("Distribution shutdown [errs=~p]", [{E1, E2}]),
      ?LOG_INFO("Distribution shut down [name=~p]", [Name])
  end.

%% @doc Connect to an existing runtime node, if available, or start one.
-spec connect() -> ok.
connect() ->
  gen_server:call(?SERVER, {connect}, infinity).

%% @doc Make a RPC call towards the runtime node.
-spec rpc_call(atom(), atom(), [any()]) -> {any(), binary()}.
rpc_call(M, F, A) ->
  rpc_call(M, F, A, ?RPC_TIMEOUT).

%% @doc Make a RPC call towards the runtime node.
-spec rpc_call(atom(), atom(), [any()], timeout()) -> {any(), binary()}.
rpc_call(M, F, A, Timeout) ->
  gen_server:call(?SERVER, {rpc_call, M, F, A, Timeout}, Timeout).

%%==============================================================================
%% Callbacks for the gen_server behaviour
%%==============================================================================
-spec init(unused) -> {ok, state()}.
init(unused) ->
  ?LOG_INFO("Ensure EPMD is running", []),
  ok = ensure_epmd(),
  {ok, #{}}.

-spec handle_call(any(), {pid(), any()}, state()) ->
        {reply, any(), state()} | {noreply, state()}.
handle_call({connect}, _From, State) ->
  Node = els_config_runtime:get_node_name(),
  case connect_and_monitor(Node) of
    ok ->
      ok;
    error ->
      ok = start(Node)
  end,
  {reply, ok, State};
handle_call({rpc_call, M, F, A, Timeout}, _From, State) ->
  {ok, P} = els_group_leader_server:new(),
  Node = els_config_runtime:get_node_name(),
  ?LOG_INFO("RPC Call [node=~p] [mfa=~p]", [Node, {M, F, A}]),
  Result = rpc:call(Node, M, F, A, Timeout),
  Output = els_group_leader_server:flush(P),
  ok = els_group_leader_server:stop(P),
  {reply, {Result, Output}, State};
handle_call(_Request, _From, State) ->
  {noreply, State}.

-spec handle_cast(any(), state()) -> {noreply, state()}.
handle_cast(_Request, State) ->
  {noreply, State}.

-spec handle_info(any(), state()) -> {noreply, state()}.
handle_info({nodedown, Node}, State) ->
  ?LOG_ERROR("Runtime node down [node=~p]", [Node]),
  {noreply, State};
handle_info(Request, State) ->
  ?LOG_WARNING("Unexpected request [request=~p]", [Request]),
  {noreply, State}.

%%==============================================================================
%% Internal Functions
%%==============================================================================
-spec connect_and_monitor(atom()) -> ok | error.
connect_and_monitor(Node) ->
  case net_kernel:connect_node(Node) of
    true ->
      ?LOG_INFO("Connected to node [node=~p]", [Node]),
      erlang:monitor_node(Node, true),
      ok;
    false ->
      error
  end.

-spec start(atom()) -> ok.
start(Node) ->
  Cmd = els_config_runtime:get_start_cmd(),
  Args = els_config_runtime:get_start_args(),
  Path = els_config_runtime:get_otp_path(),
  ?LOG_INFO( "Starting new Erlang node [node=~p] [cmd=~p] [args=~p] [path=~p]"
           , [Node, Cmd, Args, Path]
           ),
  spawn_link(fun() -> els_utils:cmd(Cmd, Args, Path) end),
  wait_connect_and_monitor(Node),
  ok.

-spec wait_connect_and_monitor(atom()) -> ok.
wait_connect_and_monitor(Node) ->
  wait_connect_and_monitor(Node, ?WAIT_ATTEMPTS).

-spec wait_connect_and_monitor(Node :: atom(), Attempts :: pos_integer()) -> ok.
wait_connect_and_monitor(Node, 0) ->
  ?LOG_ERROR( "Failed to connect to node ~p after ~p attempts"
            , [Node, ?WAIT_ATTEMPTS]),
  ok;
wait_connect_and_monitor(Node, Attempts) ->
  timer:sleep(?WAIT_INTERVAL),
  case connect_and_monitor(Node) of
    ok ->
      ok;
    error ->
      ?LOG_WARNING( "Trying to connect to node ~p (~p/~p)"
                  , [Node, ?WAIT_ATTEMPTS - Attempts + 1, ?WAIT_ATTEMPTS]),
      wait_connect_and_monitor(Node, Attempts - 1)
  end.

%% @doc Ensure the Erlang Port Mapper Daemon (EPMD) is up and running
-spec ensure_epmd() -> ok.
ensure_epmd() ->
  0 = els_utils:cmd("epmd", ["-daemon"]),
  ok.

-spec node_name(binary(), binary()) -> atom().
node_name(Prefix, Name) ->
  Int = erlang:phash2(erlang:timestamp()),
  Id = lists:flatten(io_lib:format("~s_~s_~p", [Prefix, Name, Int])),
  {ok, Hostname} = inet:gethostname(),
  case els_config_runtime:get_name_type() of
    shortnames ->
      list_to_atom(Id ++ "@" ++ Hostname);
    longnames ->
      Domain = proplists:get_value(domain, inet:get_rc(), ""),
      list_to_atom(Id ++ "@" ++ Hostname ++ "." ++ Domain)
  end.

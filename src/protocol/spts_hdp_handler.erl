-module(spts_hdp_handler).
-author('hernanrivasacosta@gmail.com').
-author('elbrujohalcon@inaka.net').

-behaviour(gen_server).

%%% gen_server callbacks
-export([
         init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3
        ]).
%%% API
-export([start_link/0, send_update/3]).
%%% For internal use only
-export([handle_udp/4]).

-define(UCHAR,  8/unsigned-integer).
-define(USHORT, 16/unsigned-integer).
-define(UINT,   32/unsigned-integer).

-record(state, {socket :: port()}).
-type state() :: #state{}.

-record(metadata, {messageId      = 0 :: integer(),
                   userTime       = 0 :: integer(),
                   userId         = 0 :: integer(),
                   socket = undefined :: port() | undefined,
                   ip     = undefined :: inet:ip_address() | undefined,
                   port   = undefined :: integer() | undefined}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% External API functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec start_link() -> {ok, pid()}.
start_link() ->
  gen_server:start_link(
    {local, ?MODULE}, ?MODULE, noargs, [{debug, [trace, log]}]).

-spec send_update(integer(), iodata(), spts_hdp_game_handler:address()) -> ok.
send_update(Tick, Message, {Ip, Port}) ->
  gen_server:cast(?MODULE, {send, Ip, Port, Tick, Message}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Callback implementation
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec init(noargs) -> {ok, state()}.
init(noargs) ->
  Port = application:get_env(serpents, udp_port, 8584),
  {ok, UdpSocket} = gen_udp:open(Port, [{mode, binary}, {reuseaddr, true}]),
  {ok, #state{socket = UdpSocket}}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast({send, Ip, Port, Tick, Message}, State) ->
  ct:pal("Send update to ~p:~p: ~p/~p", [Ip, Port, Tick, Message]),
  #state{socket = UdpSocket} = State,
  Flags = set_flags([update, success]),
  send(
    [<<Flags:?UCHAR, Tick:?UINT, Tick:?USHORT>>, Message], UdpSocket, Ip, Port),
  {noreply, State};
handle_cast(Msg, State) ->
  lager:warning("Unexpected message: ~p", [Msg]),
  {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(
  {udp, UdpSocket, Ip, Port, Bin}, State = #state{socket = UdpSocket}) ->
  _Pid = spawn(?MODULE, handle_udp, [Bin, UdpSocket, Ip, Port]),
  {noreply, State};
handle_info(_Info, State) -> {noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Unused Callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec handle_call(X, term(), state()) -> {reply, {unknown, X}, state()}.
handle_call(X, _From, State) -> {reply, {unknown, X}, State}.
-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) -> ok.
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Internal Functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec handle_udp(binary(), port(), inet:ip_address(), integer()) -> any().
handle_udp(<<Flags:?UCHAR,
             MessageId:?USHORT,
             UserTime:?USHORT,
             UserId:?USHORT,
             Message/binary>> = Data,
           UdpSocket, Ip, Port) ->
  case get_message_type(Flags band 7) of
    undefined ->
      lager:info("received bad type from ~p: ~p", [Ip, Data]);
    MessageType ->
      Metadata = #metadata{messageId = MessageId,
                           userTime = UserTime,
                           userId = UserId,
                           socket = UdpSocket,
                           ip = Ip,
                           port = Port},
      case handle_message(MessageType, Message, Metadata) of
        undefined ->
          lager:info("received bad message ~p from ~p", [Message, Ip]);
        _Ok ->
          ok
      end
  end;
% Garbage and malformed messages are simply ignored
handle_udp(MalforedMessage, _UdpSocket, Ip, _Port) ->
  lager:info("received malformed message from ~p: ~p", [Ip, MalforedMessage]),
  ok.

%% PING
handle_message(ping, _Ignored, Metadata = #metadata{messageId = MessageId,
                                                    userTime  = UserTime}) ->
  Flags = set_flags([ping, success]),
  send(<<Flags:?UCHAR,
         MessageId:?UINT,
         UserTime:?USHORT>>,
       Metadata);
%% INFO REQUESTS
handle_message(info, <<>>, Metadata = #metadata{messageId = MessageId,
                                                userTime  = UserTime}) ->
  AllGames =
    [spts_games:to_binary(Game, reduced) || Game <- spts_core:all_games()],

  NumGames = length(AllGames),
  Flags = set_flags([info, success]),
  send([<<Flags:?UCHAR,
          MessageId:?UINT,
          UserTime:?USHORT,
          NumGames:?UCHAR>>,
        AllGames], Metadata);
handle_message(info,
               <<GameId:?USHORT>>,
               Metadata = #metadata{messageId = MessageId,
                                    userTime  = UserTime}) ->
  try
    % Retrieve the game data
    GameDesc = spts_games:to_binary(spts_core:fetch_game(GameId), complete),

    Flags = set_flags([info, success]),
    send([<<Flags:?UCHAR,
            MessageId:?UINT,
            UserTime:?USHORT>>,
            GameDesc],
           Metadata)
  catch
    throw:{badgame, GameId} ->
      lager:warning("Game ~p doesn't exist", [GameId]),
      ErrorFlags = set_flags([info, error]),
      ErrorReason = spts_binary:pascal_string(<<"badgame">>),
      send(
        <<ErrorFlags:?UCHAR, MessageId:?UINT, UserTime:?USHORT,
          GameId:?USHORT, ErrorReason/binary>>, Metadata);
    A:B -> lager:warning(
            "Unexpected error ~p:~p~n~p", [A, B, erlang:get_stacktrace()]),
           ErrorFlags = set_flags([info, error]),
           ErrorReason = "unspecified",
           ErrorReasonLength = length(ErrorReason),
           send([<<ErrorFlags:?UCHAR,
                   MessageId:?UINT,
                   UserTime:?USHORT,
                   GameId:?USHORT,
                   ErrorReasonLength:?UCHAR>>,
                 ErrorReason],
                Metadata)
  end;
  
%% JOIN COMMAND
handle_message(join,
               <<GameId:?USHORT,
                 NameSize:?UCHAR,
                 Name:NameSize/binary>>,
               Metadata = #metadata{messageId = MessageId,
                                    userTime  = UserTime}) ->
  try
    Address = {Metadata#metadata.ip, Metadata#metadata.port},
    SerpentId = spts_hdp_game_handler:user_connected(Name, Address, GameId),

    % Retrieve the game data
    GameDesc = spts_games:to_binary(spts_core:fetch_game(GameId), complete),

    % Build the response
    Flags = set_flags([join, success]),
    send([<<Flags:?UCHAR,
            MessageId:?UINT,
            UserTime:?USHORT,
            SerpentId:?UINT>>,
          GameDesc],
         Metadata)
  catch
    throw:{badgame, GameId} ->
      lager:warning("Game ~p doesn't exist", [GameId]),
      ErrorFlags = set_flags([join, error]),
      ErrorReason = spts_binary:pascal_string(<<"badgame">>),
      send(
        <<ErrorFlags:?UCHAR, MessageId:?UINT, UserTime:?USHORT,
          GameId:?USHORT, ErrorReason/binary>>, Metadata);
    A:B -> lager:warning(
            "Unexpected error ~p:~p~n~p", [A, B, erlang:get_stacktrace()]),
           ErrorFlags = set_flags([join, error]),
           ErrorReason = "unspecified",
           ErrorReasonLength = length(ErrorReason),
           send([<<ErrorFlags:?UCHAR,
                   MessageId:?UINT,
                   UserTime:?USHORT,
                   GameId:?USHORT,
                   ErrorReasonLength:?UCHAR>>,
                 ErrorReason],
                Metadata)
  end;
handle_message(
  action, <<LastServerTick:?USHORT, Direction:?UCHAR>>, Metadata) ->
  Address = {Metadata#metadata.socket, Metadata#metadata.port},
  spts_hdp_game_handler:user_update(
    Metadata#metadata.userId, Address, LastServerTick, Direction);
handle_message(_MessageType, _Garbage, _Metadata) ->
  undefined.

%%==============================================================================
%% Utils
%%==============================================================================
get_message_type(1) -> ping;
get_message_type(2) -> info;
get_message_type(3) -> join;
get_message_type(4) -> action;
get_message_type(_Garbage) -> undefined.

set_flags(Flags) ->
  set_flags(Flags, 0).
set_flags(Flags, Value) ->
  lists:foldl(fun set_flag/2, Value, Flags).

set_flag(ping, Value) -> (Value band 248) bor 1;
set_flag(info, Value) -> (Value band 248) bor 2;
set_flag(join, Value) -> (Value band 248) bor 3;
set_flag(action, Value) -> (Value band 248) bor 4;
% Update is the server side equivalent of action
set_flag(update, Value) -> set_flag(action, Value);
set_flag(success, Value) -> Value bor 128;
set_flag(error, Value) -> Value band 127.

send(Message, #metadata{socket = UdpSocket, ip = Ip, port = Port}) ->
  send(Message, UdpSocket, Ip, Port).

send(Message, UdpSocket, Ip, Port) ->
  ok = gen_udp:send(UdpSocket, Ip, Port, Message).

-module(spts_api_news_SUITE).
-author('elbrujohalcon@inaka.net').

-include_lib("mixer/include/mixer.hrl").
-mixin([
        {spts_test_utils,
         [ init_per_suite/1
         , end_per_suite/1
         ]}
       ]).

-export([all/0]).
-export([ get_news_wrong/1
        , game_status/1
        , serpent_added/1
        , game_countdown/1
        , game_started/1
        , game_updated/1
        , collision_detected/1
        , game_finished/1
        , ignored_event/1
        ]).

-spec all() -> [atom()].
all() -> spts_test_utils:all(?MODULE).

-spec get_news_wrong(spts_test_utils:config()) -> {comment, []}.
get_news_wrong(_Config) ->
  ct:comment("Trying to get news from a game that doesn't exist"),
  #{status_code := 404} =
    spts_test_utils:api_call(get, "/games/not-a-game/news"),

  {comment, ""}.

-spec game_status(spts_test_utils:config()) -> {comment, []}.
game_status(_Config) ->
  ct:comment("A game is created"),
  Headers = #{<<"content-type">> => <<"application/json">>},
  ReqBody = spts_json:encode(#{}),
  #{status_code := 201,
           body := Body} =
    spts_test_utils:api_call(post, "/games", Headers, ReqBody),
  #{<<"id">> := GameId} = Game = spts_json:decode(Body),

  ct:comment("A client connects, the first event is game_status"),
  Game = get_game_status(GameId),

  ct:comment("Another client connects, the first event is still game_status"),
  Game = get_game_status(GameId),

  {comment, ""}.

-spec serpent_added(spts_test_utils:config()) -> {comment, []}.
serpent_added(_Config) ->
  ct:comment("A game is created"),
  GameId = spts_games:id(spts_core:create_game()),

  ct:comment("A serpent is added and the client receives an event"),
  Task = fun() -> _ = spts_core:add_serpent(GameId, <<"sa">>) end,
  {Serpent, [#{data := Data}]} =
    spts_test_utils:get_events_after(
      <<"/games/", GameId/binary, "/news">>, <<"serpent_added">>, Task),

  [{Row, Col}] = spts_serpents:body(Serpent),
  #{ <<"name">> := <<"sa">>
   , <<"body">> := [[Row, Col]]
   , <<"status">> := <<"alive">>
   } = spts_json:decode(Data),

  {comment, ""}.

-spec game_countdown(spts_test_utils:config()) -> {comment, []}.
game_countdown(_Config) ->
  ct:comment("A game is created"),
  GameId = spts_games:id(spts_core:create_game()),

  ct:comment("A serpent is added"),
  _ = spts_core:add_serpent(GameId, <<"gc">>),

  ct:comment("The game is started and the client receives an event"),
  Task = fun() -> spts_core:start_game(GameId) end,
  {ok, [#{data := Data}]} =
    spts_test_utils:get_events_after(
      <<"/games/", GameId/binary, "/news">>, <<"game_countdown">>, Task),

  #{status_code := 200,
           body := Body} =
    spts_test_utils:api_call(get, <<"/games/", GameId/binary>>),
  Game = spts_json:decode(Body),

  ct:comment("The event body should reflect the current state of the game"),
  Game = spts_json:decode(Data),

  {comment, ""}.

-spec game_started(spts_test_utils:config()) -> {comment, []}.
game_started(_Config) ->
  ct:comment("A game is created"),
  GameId = spts_games:id(spts_core:create_game(#{countdown => 0})),

  ct:comment("A serpent is added"),
  _ = spts_core:add_serpent(GameId, <<"gs">>),

  ct:comment("The game is started and the client receives an event"),
  Task = fun() -> spts_core:start_game(GameId) end,
  {ok, [#{data := Data}]} =
    spts_test_utils:get_events_after(
      <<"/games/", GameId/binary, "/news">>, <<"game_started">>, Task),

  #{status_code := 200,
           body := Body} =
    spts_test_utils:api_call(get, <<"/games/", GameId/binary>>),
  Game = spts_json:decode(Body),

  ct:comment("The event body should reflect the current state of the game"),
  Game = spts_json:decode(Data),

  {comment, ""}.

-spec game_updated(spts_test_utils:config()) -> {comment, []}.
game_updated(_Config) ->
  ct:comment("A game is created"),
  GameId =
    spts_games:id(spts_core:create_game(#{countdown => 0, ticktime => 60000})),

  ct:comment("A serpent is added and the game is started"),
  _ = spts_core:add_serpent(GameId, <<"gu">>),
  spts_core:start_game(GameId),

  ct:comment("The game ticks and the client receives an event"),
  Task = fun() -> spts_games:process_name(GameId) ! tick end,
  {tick, [#{data := Data}]} =
    spts_test_utils:get_events_after(
      <<"/games/", GameId/binary, "/news">>, <<"game_updated">>, Task),

  #{status_code := 200,
           body := Body} =
    spts_test_utils:api_call(get, <<"/games/", GameId/binary>>),
  Game = spts_json:decode(Body),

  ct:comment("The event body should reflect the current state of the game"),
  Game = spts_json:decode(Data),

  {comment, ""}.

-spec collision_detected(spts_test_utils:config()) -> {comment, []}.
collision_detected(_Config) ->
  ct:comment("A game is created"),
  GameId =
    spts_games:id(
      spts_core:create_game(
        #{rows => 5, cols => 5, countdown => 0, ticktime => 60000})),

  ct:comment("A serpent is added, the game is started and played till the end"),
  _ = spts_core:add_serpent(GameId, <<"gu">>),
  spts_core:start_game(GameId),

  ct:comment("The game ticks and the client receives an event"),
  Task = tick(GameId, 6),
  {ok, [#{data := Data}]} =
    spts_test_utils:get_events_after(
      <<"/games/", GameId/binary, "/news">>, <<"collision_detected">>, Task),

  #{status_code := 200,
           body := Body} =
    spts_test_utils:api_call(get, <<"/games/", GameId/binary>>),
  #{<<"serpents">> := [Serpent]} = spts_json:decode(Body),

  ct:comment("The event body should reflect the current state of the serpent"),
  Serpent = spts_json:decode(Data),

  {comment, ""}.

-spec game_finished(spts_test_utils:config()) -> {comment, []}.
game_finished(_Config) ->
  ct:comment("A game is created"),
  GameId =
    spts_games:id(
      spts_core:create_game(
        #{rows => 5, cols => 5, countdown => 0, ticktime => 60000})),

  ct:comment("A serpent is added, the game is started and played till the end"),
  _ = spts_core:add_serpent(GameId, <<"gu">>),
  spts_core:start_game(GameId),

  ct:comment("The game ticks and the client receives an event"),
  Task = tick(GameId, 6),
  {ok, [#{data := Data}]} =
    spts_test_utils:get_events_after(
      <<"/games/", GameId/binary, "/news">>, <<"game_finished">>, Task),

  #{status_code := 200,
           body := Body} =
    spts_test_utils:api_call(get, <<"/games/", GameId/binary>>),
  Game = spts_json:decode(Body),

  ct:comment("The event body should reflect the current state of the game"),
  Game = spts_json:decode(Data),

  {comment, ""}.

-spec ignored_event(spts_test_utils:config()) -> {comment, []}.
ignored_event(_Config) ->
  ct:comment("A game is created"),
  GameId = spts_games:id(spts_core:create_game()),

  {ok, Dispatcher} =
    gen_fsm:sync_send_all_state_event(
      spts_games:process_name(GameId), dispatcher),

  ct:comment("An unknown event is sent and the client receives nothing"),
  Task1 = fun() -> gen_event:notify(Dispatcher, unknown_event) end,
  ok =
    spts_test_utils:no_events_after(
      <<"/games/", GameId/binary, "/news">>, Task1),

  ct:comment("An unknown info message is sent and the client receives nothing"),
  Task2 = fun() -> Dispatcher ! unknown_info, ok end,
  ok =
    spts_test_utils:no_events_after(
      <<"/games/", GameId/binary, "/news">>, Task2),

  {comment, ""}.

get_game_status(GameId) ->
  [#{data := DataBin}] =
    spts_test_utils:get_events(
      <<"/games/", GameId/binary, "/news">>, <<"game_status">>),
  spts_json:decode(DataBin).

tick(GameId, Ticks) ->
  fun() ->
    lists:foreach(
      fun(_) ->
        spts_games:process_name(GameId) ! tick
      end, lists:seq(1, Ticks))
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc OAuth2 Authentication Token Cache - This gen_server implements a
%%% simple caching mechanism for authentication tokens.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration ===============================================
-module(oauth2c_token_cache).
-behaviour(gen_server).

%%%_* Exports ==========================================================

-export([start/0]).
-export([start/1]).
-export([start_link/0]).
-export([start_link/1]).
-export([get/1]).
-export([set_and_get/2]).
-export([set_and_get/3]).

%% gen_server
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([clear/0]).

%%%_* Macros =========================================================

-define(DEFAULT_TTL, 3600). % Default cache entry TTL in seconds.
-define(SERVER, ?MODULE).
-define(TOKEN_CACHE_ID, token_cache_id).

%%%_* Includes =========================================================

%%%_* Code =============================================================
%%%_ * Types -----------------------------------------------------------
%%%_ * API -------------------------------------------------------------

-spec start() -> {atom(), pid()}.
start() ->
  start(?DEFAULT_TTL).
-spec start(non_neg_integer()) -> {atom(), pid()}.
start(DefaultTTL) ->
  gen_server:start({local, ?SERVER}, ?SERVER,
                   #{default_ttl => DefaultTTL}, []).

-spec start_link() -> {atom(), pid()}.
start_link() ->
  start_link(?DEFAULT_TTL).
-spec start_link(non_neg_integer()) -> {atom(), pid()}.
start_link(DefaultTTL) ->
  gen_server:start_link({local, ?SERVER}, ?SERVER,
                        #{default_ttl => DefaultTTL}, []).

-spec get(integer()) -> {error, atom()} | {ok, term()}.
get(Key) ->
  Now = erlang:system_time(second),
  case get_cached_token(Key,
                   Now,
                   ets:lookup(?TOKEN_CACHE_ID, Key))
  of
    {ok, Result, _ExpiryTime} -> {ok, Result};
    {error, Reason} -> {error, Reason}
  end.

-spec set_and_get(Key, LazyValue) -> Value | Error when
    Key :: integer(),
    LazyValue :: fun(() -> Value | Error),
    Value :: {ok, term()},
    Error :: {error, binary()}.
set_and_get(Key, LazyValue) ->
  set_and_get(Key, LazyValue, []).

-spec set_and_get(Key, LazyValue, Options) -> Value | Error when
    Key :: integer(),
    LazyValue :: fun(() -> Value | Error),
    Options :: list(),
    Value :: {ok,  term()},
    Error :: {error, atom()}.
set_and_get(Key, LazyValue, Options) ->
  gen_server:call(?SERVER, {set_and_get, Key, LazyValue, Options}).

-spec clear() -> true.
clear() ->
  ets:delete_all_objects(?TOKEN_CACHE_ID).

%%%_ * gen_server callbacks --------------------------------------------

init(State) ->
  EtsOpts = [set, public, named_table, {read_concurrency, true}],
  ets:new(?TOKEN_CACHE_ID, EtsOpts),
  {ok, State}.

handle_call({set_and_get, Key, LazyValue, Options}, _From,
  State = #{default_ttl := DefaultTTL}) ->
  ForceUpdateLimit =
    proplists:get_value(force_update_entries_older_or_equal_than,
                        Options,
                        undefined),
  % The expiry time of the token the user wishes to delete
  % is needed in order to uniquely indentify a cached access token.
  % It could be the case that the token the user wishes to delete has
  % already been deleted and refreshed by a concurrent thread. If we would
  % not use the ExpireTime, we cold accidently delete a valid refreshed token.
  Now = erlang:system_time(second),
  case get_cached_token( Key
                       , Now
                       , ets:lookup(?TOKEN_CACHE_ID, Key))
  of
    {ok, Result, ThisExpiryTime}
      when ForceUpdateLimit =:= undefined orelse
           (ThisExpiryTime > ForceUpdateLimit) ->
      {reply, {ok, Result}, State};
    _ ->
      case LazyValue() of
        {ok, Result, ExpiryTime0} ->
          ExpiryTime = get_expiry_time(ExpiryTime0, DefaultTTL),
          ets:insert(?TOKEN_CACHE_ID,
            {Key, Result, ExpiryTime}),
          {reply, {ok, Result}, State};
        {error, Reason} -> {reply, {error, Reason}, State}
      end
  end.

handle_cast(_, State) -> {noreply, State}.

%%%_ * Private functions -----------------------------------------------

get_cached_token( Key
                , Now
                , [{Key, Result, ExpiryTime}]
                ) when ExpiryTime > Now ->
  {ok, Result, ExpiryTime};
get_cached_token(_Key, _Now, _) -> {error, not_found}.

get_expiry_time(undefined, DefaultTTL) ->
  erlang:system_time(second) + DefaultTTL;
get_expiry_time(ExpiryTime, _DefaultTTL) ->
  ExpiryTime.

%%%_ * Tests -------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

get_expiry_time_test_() ->
  [
      fun() ->
          {T, Default} = Input,
          Actual = get_expiry_time(T, Default),
          ?assertEqual(Expected, Actual)
      end
  ||
      {Input, Expected} <-[
          {{1, 100}, 1}
      ]
  ].

  get_cached_token_test_() ->
  [
      fun() ->
          {Key, Now, Token} = Input,
          Actual = get_cached_token(Key, Now, Token),
          ?assertEqual(Expected, Actual)
      end
  ||
      {Input, Expected} <-[
          {{k1, 100, [{k1, c, 101}]},
            {ok, c, 101}},
          {{k1, 100, [{k1, c, 99}]},
            {error, not_found}},
          {{k1, 100, [{k2, c, 101}]},
            {error, not_found}}
      ]
  ].

-endif.

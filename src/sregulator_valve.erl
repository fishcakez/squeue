%%-------------------------------------------------------------------
%%
%% Copyright (c) 2015, James Fish <james@fishcakez.com>
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License. You may obtain
%% a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%%-------------------------------------------------------------------
%% @private
-module(sregulator_valve).

%% public api

-export([new/2]).
-export([in/3]).
-export([out/1]).
-export([out/2]).
-export([cancel/3]).
-export([down/3]).
-export([len/1]).
-export([config_change/2]).
-export([timeout/2]).
-export([open/1]).
-export([close/1]).
-export([sojourn/3]).
-export([dropped/2]).

%% types

-record(drop_valve, {module :: module(),
                     args :: any(),
                     squeue_module :: module(),
                     squeue_args :: any(),
                     out :: out | out_r,
                     drop_out :: out | out_r,
                     size :: non_neg_integer() | infinity,
                     len = 0 :: non_neg_integer(),
                     svalve = svalve:new() :: svalve:svalve()}).

-type tag() :: any().
-type queue_spec() ::
    {module(), any(), out | out_r, non_neg_integer() | infinity, drop | drop_r}.
-type spec() :: {module(), any(), queue_spec()}.
-opaque drop_valve() :: #drop_valve{}.

-export_type([spec/0]).
-export_type([drop_valve/0]).

%% public api

-spec new(Time, Spec) -> Q when
      Time :: non_neg_integer(),
      Spec :: spec(),
      Q :: drop_valve().
new(Time, {Mod, Args, {SMod, SArgs, Out, Size, Drop}})
  when (Out =:= out orelse Out =:= out_r) andalso
       ((is_integer(Size) andalso Size >= 0) orelse Size =:= infinity) ->
    V = svalve:new(Time, Mod, Args),
    S = squeue:new(Time, SMod, SArgs),
    NV = svalve:squeue(S, V),
    #drop_valve{module=Mod, args=Args, squeue_module=SMod, squeue_args=SArgs,
                out=Out, drop_out=drop_out(Drop), size=Size, svalve=NV}.

-spec in(Time, From, Q) -> NQ when
      Time :: non_neg_integer(),
      From :: {pid(), tag()},
      Q :: drop_valve(),
      NQ :: drop_valve().
in(Time, {Pid, _} = From,
   #drop_valve{drop_out=DropOut, size=Size, len=Len, svalve=V} = Q) ->
    Ref = monitor(process, Pid),
    {Drops, NV} = svalve:in(Time, {Ref, From}, V),
    case Len - drops(Drops) + 1 of
        NLen when NLen > Size ->
            {Dropped, NV2} = drop_out(DropOut, NLen - Size, NV),
            Q#drop_valve{len=NLen-Dropped, svalve=NV2};
        NLen ->
            Q#drop_valve{len=NLen, svalve=NV}
    end.

-spec out(Q) -> {Result, NQ} when
      Q :: drop_valve(),
      Result :: empty | {SojournTime, {Ref, From}},
      SojournTime :: non_neg_integer(),
      Ref ::  reference(),
      From :: {pid(), tag()},
      NQ :: drop_valve().
out(#drop_valve{out=Out, len=Len, svalve=V} = Q) ->
    case svalve:Out(V) of
        {empty, Drops, NV} ->
            {empty, maybe_drop(Q#drop_valve{len=Len-drops(Drops), svalve=NV})};
        {Item, Drops, NV} ->
            {Item, maybe_drop(Q#drop_valve{len=Len-drops(Drops)-1, svalve=NV})}
    end.

-spec out(Time, Q) -> {Result, NQ} when
      Time :: non_neg_integer(),
      Q :: drop_valve(),
      Result :: empty | {SojournTime, {Ref, From}},
      SojournTime :: non_neg_integer(),
      Ref ::  reference(),
      From :: {pid(), tag()},
      NQ :: drop_valve().
out(Time, #drop_valve{out=Out, len=Len, svalve=V} = Q) ->
    case svalve:Out(Time, V) of
        {empty, Drops, NV} ->
            {empty, maybe_drop(Q#drop_valve{len=Len-drops(Drops), svalve=NV})};
        {Item, Drops, NV} ->
            {Item, maybe_drop(Q#drop_valve{len=Len-drops(Drops)-1, svalve=NV})}
    end.

-spec cancel(Time, Tag, Q) -> {Cancelled, NQ} when
      Time :: non_neg_integer(),
      Tag :: tag(),
      Q :: drop_valve(),
      Cancelled :: pos_integer() | false,
      NQ :: drop_valve().
cancel(Time, Tag, #drop_valve{len=Len, svalve=V} = Q) ->
    Cancel = fun({Ref, {_, Tag2}}) when Tag2 =:= Tag ->
                     demonitor(Ref, [flush]),
                     false;
                (_) ->
                     true
             end,
    {Drops, NV} = svalve:filter(Time, Cancel, V),
    Dropped = drops(Drops),
    NLen = svalve:len(NV),
    NQ = maybe_drop(Q#drop_valve{len=NLen, svalve=NV}),
    case Len - Dropped - NLen of
        0 ->
            {false, NQ};
        Cancelled ->
            {Cancelled, NQ}
    end.

-spec down(Time, Ref, Q) -> NQ when
      Time :: non_neg_integer(),
      Ref :: reference(),
      Q :: drop_valve(),
      NQ :: drop_valve().
down(Time, Ref, #drop_valve{svalve=V} = Q) ->
    {Drops, NV} = svalve:filter(Time, fun({Ref2, _}) -> Ref2 =/= Ref end, V),
    _ = drops(Drops),
    maybe_drop(Q#drop_valve{len=svalve:len(NV), svalve=NV}).

-spec len(V) -> Len when
      V :: drop_valve(),
      Len :: non_neg_integer().
len(#drop_valve{len=Len}) ->
    Len.

-spec config_change(Spec, Q) -> NQ when
      Spec :: spec(),
      Q :: drop_valve(),
      NQ :: drop_valve().
config_change({Mod, Args, {SMod, SArgs, Out, Size, Drop}},
              #drop_valve{module=Mod, args=Args} = Q) ->
    NQ = Q#drop_valve{out=Out, size=Size, drop_out=drop_out(Drop)},
    config_change_squeue(SMod, SArgs, NQ);
config_change({_, _, {NSMod, NSArgs, _, _, _}} = Spec,
              #drop_valve{squeue_module=SMod, squeue_args=SArgs,
                          len=Len, svalve=V}) ->
    Time = svalve:time(V),
    #drop_valve{svalve=NV} = NQ = new(Time, Spec),
    S = svalve:squeue(V),
    NV2 = svalve:squeue(S, NV),
    NQ2 = NQ#drop_valve{squeue_module=SMod, squeue_args=SArgs, len=Len,
                        svalve=NV2},
    config_change_squeue(NSMod, NSArgs, NQ2).

-spec timeout(Time, Q) -> NQ when
      Time :: non_neg_integer(),
      Q :: drop_valve(),
      NQ :: drop_valve().
timeout(Time, #drop_valve{len=Len, svalve=V} = Q) ->
    {Drops, NV} = svalve:timeout(Time, V),
    maybe_drop(Q#drop_valve{len=Len-drops(Drops), svalve=NV}).


-spec open(Q) -> NQ when
      Q :: drop_valve(),
      NQ :: drop_valve().
open(#drop_valve{svalve=V} = Q) ->
    Q#drop_valve{svalve=svalve:open(V)}.

-spec close(Q) -> NQ when
      Q :: drop_valve(),
      NQ :: drop_valve().
close(#drop_valve{svalve=V} = Q) ->
    Q#drop_valve{svalve=svalve:close(V)}.

-spec sojourn(Time, SojournTime, Q) -> {Result, NQ} when
      Time :: non_neg_integer(),
      SojournTime :: non_neg_integer(),
      Q :: drop_valve(),
      Result :: closed | empty | {FromSojournTime, {Ref, From}},
      FromSojournTime :: non_neg_integer(),
      Ref ::  reference(),
      From :: {pid(), tag()},
      NQ :: drop_valve().
sojourn(Time, SojournTime, #drop_valve{out=out, len=Len, svalve=V} = Q) ->
    case svalve:sojourn(Time, SojournTime, V) of
        {{_, _} = Item, Drops, NV} ->
            {Item, maybe_drop(Q#drop_valve{len=Len-drops(Drops)-1, svalve=NV})};
        {Result, Drops, NV} ->
            {Result, maybe_drop(Q#drop_valve{len=Len-drops(Drops), svalve=NV})}
    end;
sojourn(Time, SojournTime, #drop_valve{out=out_r, len=Len, svalve=V} = Q) ->
    case svalve:sojourn_r(Time, SojournTime, V) of
        {{_, _} = Item, Drops, NV} ->
            {Item, maybe_drop(Q#drop_valve{len=Len-drops(Drops)-1, svalve=NV})};
        {Result, Drops, NV} ->
            {Result, maybe_drop(Q#drop_valve{len=Len-drops(Drops), svalve=NV})}
    end.

-spec dropped(Time, Q) -> {Result, NQ} when
      Time :: non_neg_integer(),
      Q :: drop_valve(),
      Result :: closed | empty | {FromSojournTime, {Ref, From}},
      FromSojournTime :: non_neg_integer(),
      Ref ::  reference(),
      From :: {pid(), tag()},
      NQ :: drop_valve().
dropped(Time, #drop_valve{out=out, len=Len, svalve=V} = Q) ->
    case svalve:dropped(Time, V) of
        {{_, _} = Item, Drops, NV} ->
            {Item, maybe_drop(Q#drop_valve{len=Len-drops(Drops)-1, svalve=NV})};
        {Result, Drops, NV} ->
            {Result, maybe_drop(Q#drop_valve{len=Len-drops(Drops), svalve=NV})}
    end;
dropped(Time, #drop_valve{out=out_r, len=Len, svalve=V} = Q) ->
    case svalve:dropped_r(Time, V) of
        {{_, _} = Item, Drops, NV} ->
            {Item, maybe_drop(Q#drop_valve{len=Len-drops(Drops)-1, svalve=NV})};
        {Result, Drops, NV} ->
            {Result, maybe_drop(Q#drop_valve{len=Len-drops(Drops), svalve=NV})}
    end.

%% Internal

drop_out(drop) -> out;
drop_out(drop_r) -> out_r.

drop_out(DropOut, ToDrop, S) ->
    drop_loop(svalve:DropOut(S), DropOut, ToDrop, 0).

drop_loop({empty, Drops, S}, _, _, Dropped) ->
    {Dropped + drops(Drops), S};
drop_loop({Item, Drops, S}, DropOut, ToDrop, Dropped) ->
    drop(Item),
    case Dropped + 1 + drops(Drops) of
        NDropped when NDropped < ToDrop ->
            drop_loop(svalve:DropOut(S), DropOut, ToDrop, NDropped);
        NDropped ->
            {NDropped, S}
    end.

drops(Items) ->
    drops(Items, 0).

drops([Item | Rest], N) ->
    drop(Item),
    drops(Rest, N+1);
drops([], N) ->
    N.

drop({SojournTime, {Ref, From}}) ->
    demonitor(Ref, [flush]),
    gen_fsm:reply(From, {drop, SojournTime}).

maybe_drop(#drop_valve{size=Size, len=Len, drop_out=DropOut, svalve=V} = Q)
  when Len > Size ->
    {Dropped, NV} = drop_out(DropOut, Len - Size, V),
    Q#drop_valve{len=Len-Dropped, svalve=NV};
maybe_drop(Q) ->
    Q.

config_change_squeue(SMod, SArgs, #drop_valve{squeue_module=SMod,
                                              squeue_args=SArgs} = Q) ->
    Q;
config_change_squeue(SMod, SArgs, #drop_valve{svalve=V} = Q) ->
    Time = svalve:time(V),
    NS = squeue:new(Time, SMod, SArgs),
    NV = svalve:squeue(NS, V),
    Q#drop_valve{squeue_module=SMod, squeue_args=SArgs,
                 svalve=svalve:join(NV, V)}.
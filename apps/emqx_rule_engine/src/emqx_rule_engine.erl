%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_rule_engine).

-include("rule_engine.hrl").
-include_lib("emqx/include/logger.hrl").

-export([ load_providers/0
        , unload_providers/0
        , refresh_resources/0
        , refresh_resource/1
        , refresh_rule/1
        , refresh_rules/0
        , refresh_actions/1
        , refresh_actions/2
        , refresh_resource_status/0
        ]).

-export([ create_rule/1
        , update_rule/1
        , delete_rule/1
        , create_resource/1
        , test_resource/1
        , start_resource/1
        , get_resource_status/1
        , get_resource_params/1
        , delete_resource/1
        , update_resource/2
        ]).

-export([ init_resource/4
        , init_action/4
        , clear_resource/3
        , clear_rule/1
        , clear_actions/1
        , clear_action/3
        ]).

-type(rule() :: #rule{}).
-type(action() :: #action{}).
-type(resource() :: #resource{}).
-type(resource_type() :: #resource_type{}).
-type(resource_params() :: #resource_params{}).
-type(action_instance_params() :: #action_instance_params{}).

-export_type([ rule/0
             , action/0
             , resource/0
             , resource_type/0
             , resource_params/0
             , action_instance_params/0
             ]).

-define(T_RETRY, 60000).

%%------------------------------------------------------------------------------
%% Load resource/action providers from all available applications
%%------------------------------------------------------------------------------

%% Load all providers .
-spec(load_providers() -> ok).
load_providers() ->
    lists:foreach(fun(App) ->
        load_provider(App)
    end, ignore_lib_apps(application:loaded_applications())).

-spec(load_provider(App :: atom()) -> ok).
load_provider(App) when is_atom(App) ->
    ok = load_actions(App),
    ok = load_resource_types(App).

%%------------------------------------------------------------------------------
%% Unload providers
%%------------------------------------------------------------------------------
%% Load all providers .
-spec(unload_providers() -> ok).
unload_providers() ->
    lists:foreach(fun(App) ->
        unload_provider(App)
    end, ignore_lib_apps(application:loaded_applications())).

%% @doc Unload a provider.
-spec(unload_provider(App :: atom()) -> ok).
unload_provider(App) ->
    ok = emqx_rule_registry:remove_actions_of(App),
    ok = emqx_rule_registry:unregister_resource_types_of(App).

load_actions(App) ->
    Actions = find_actions(App),
    emqx_rule_registry:add_actions(Actions).

load_resource_types(App) ->
    ResourceTypes = find_resource_types(App),
    emqx_rule_registry:register_resource_types(ResourceTypes).

-spec(find_actions(App :: atom()) -> list(action())).
find_actions(App) ->
    lists:map(fun new_action/1, find_attrs(App, rule_action)).

-spec(find_resource_types(App :: atom()) -> list(resource_type())).
find_resource_types(App) ->
    lists:map(fun new_resource_type/1, find_attrs(App, resource_type)).

new_action({App, Mod, #{name := Name,
                        for := Hook,
                        types := Types,
                        create := Create,
                        params := ParamsSpec} = Params}) ->
    ok = emqx_rule_validator:validate_spec(ParamsSpec),
    #action{name = Name, for = Hook, app = App, types = Types,
            category = maps:get(category, Params, other),
            module = Mod, on_create = Create,
            hidden = maps:get(hidden, Params, false),
            on_destroy = maps:get(destroy, Params, undefined),
            params_spec = ParamsSpec,
            title = maps:get(title, Params, ?descr),
            description = maps:get(description, Params, ?descr)}.

new_resource_type({App, Mod, #{name := Name,
                               params := ParamsSpec,
                               create := Create} = Params}) ->
    ok = emqx_rule_validator:validate_spec(ParamsSpec),
    #resource_type{name = Name, provider = App,
                   params_spec = ParamsSpec,
                   on_create = {Mod, Create},
                   on_status = {Mod, maps:get(status, Params, undefined)},
                   on_destroy = {Mod, maps:get(destroy, Params, undefined)},
                   title = maps:get(title, Params, ?descr),
                   description = maps:get(description, Params, ?descr)}.

find_attrs(App, Def) ->
    [{App, Mod, Attr} || {ok, Modules} <- [application:get_key(App, modules)],
                         Mod <- Modules,
                         {Name, Attrs} <- module_attributes(Mod), Name =:= Def,
                         Attr <- Attrs].

module_attributes(Module) ->
    try Module:module_info(attributes)
    catch
        error:undef -> []
    end.

%%------------------------------------------------------------------------------
%% APIs for rules and resources
%%------------------------------------------------------------------------------

-dialyzer([{nowarn_function, [create_rule/1, rule_id/0]}]).
-spec create_rule(map()) -> {ok, rule()} | {error, term()}.
create_rule(Params = #{rawsql := Sql, actions := ActArgs}) ->
    case emqx_rule_sqlparser:parse_select(Sql) of
        {ok, Select} ->
            RuleId = maps:get(id, Params, rule_id()),
            Enabled = maps:get(enabled, Params, true),
            try prepare_actions(ActArgs, Enabled) of
                Actions ->
                    Rule = #rule{
                        id = RuleId,
                        rawsql = Sql,
                        for = emqx_rule_sqlparser:select_from(Select),
                        is_foreach = emqx_rule_sqlparser:select_is_foreach(Select),
                        fields = emqx_rule_sqlparser:select_fields(Select),
                        doeach = emqx_rule_sqlparser:select_doeach(Select),
                        incase = emqx_rule_sqlparser:select_incase(Select),
                        conditions = emqx_rule_sqlparser:select_where(Select),
                        on_action_failed = maps:get(on_action_failed, Params, continue),
                        actions = Actions,
                        enabled = Enabled,
                        created_at = erlang:system_time(millisecond),
                        description = maps:get(description, Params, ""),
                        state = normal
                    },
                    ok = emqx_rule_registry:add_rule(Rule),
                    ok = emqx_rule_metrics:create_rule_metrics(RuleId),
                    {ok, Rule}
            catch
                throw:{action_not_found, ActionName} ->
                    {error, {action_not_found, ActionName}};
                throw:Reason ->
                    {error, Reason}
            end;
        Reason -> {error, Reason}
    end.

-spec(update_rule(#{id := binary(), _=>_}) -> {ok, rule()} | {error, {not_found, rule_id()}}).
update_rule(Params = #{id := RuleId}) ->
    case emqx_rule_registry:get_rule(RuleId) of
        {ok, Rule0} ->
            try may_update_rule_params(Rule0, Params) of
                Rule ->
                    ok = emqx_rule_registry:add_rule(Rule),
                    {ok, Rule}
            catch
                throw:Reason ->
                    {error, Reason}
            end;
        not_found ->
            {error, {not_found, RuleId}}
    end.

-spec(delete_rule(RuleId :: rule_id()) -> ok).
delete_rule(RuleId) ->
    case emqx_rule_registry:get_rule(RuleId) of
        {ok, Rule = #rule{actions = Actions}} ->
            try
                _ = ?CLUSTER_CALL(clear_rule, [Rule]),
                ok = emqx_rule_registry:remove_rule(Rule)
            catch
                Error:Reason:ST ->
                    ?LOG(error, "clear_rule ~p failed: ~p", [RuleId, {Error, Reason, ST}]),
                    refresh_actions(Actions)
            end;
        not_found ->
            ok
    end.

-spec(create_resource(#{type := _, config := _, _ => _}) -> {ok, resource()} | {error, Reason :: term()}).
create_resource(#{type := Type, config := Config0} = Params) ->
    case emqx_rule_registry:find_resource_type(Type) of
        {ok, #resource_type{on_create = {M, F}, params_spec = ParamSpec}} ->
            Config = emqx_rule_validator:validate_params(Config0, ParamSpec),
            ResId = maps:get(id, Params, resource_id()),
            Resource = #resource{id = ResId,
                                 type = Type,
                                 config = Config,
                                 description = iolist_to_binary(maps:get(description, Params, "")),
                                 created_at = erlang:system_time(millisecond)
                                },
            ok = emqx_rule_registry:add_resource(Resource),
            %% Note that we will return OK in case of resource creation failure,
            %% A timer is started to re-start the resource later.
            catch _ = ?CLUSTER_CALL(init_resource, [M, F, ResId, Config]),
            {ok, Resource};
        not_found ->
            {error, {resource_type_not_found, Type}}
    end.

-spec(update_resource(resource_id(), map()) -> ok | {error, Reason :: term()}).
update_resource(ResId, NewParams) ->
    case emqx_rule_registry:find_enabled_rules_depends_on_resource(ResId) of
        [] -> check_and_update_resource(ResId, NewParams);
        Rules ->
            {error, {dependent_rules_exists, [Id || #rule{id = Id} <- Rules]}}
    end.

check_and_update_resource(Id, NewParams) ->
    case emqx_rule_registry:find_resource(Id) of
        {ok, #resource{id = Id, type = Type, config = OldConfig, description = OldDescr}} ->
            try
                Conifg = maps:get(<<"config">>, NewParams, OldConfig),
                Descr = maps:get(<<"description">>, NewParams, OldDescr),
                do_check_and_update_resource(#{id => Id, config => Conifg, type => Type,
                    description => Descr})
            catch Error:Reason:ST ->
                ?LOG(error, "check_and_update_resource failed: ~0p", [{Error, Reason, ST}]),
                {error, Reason}
            end;
        _Other ->
            {error, not_found}
    end.

do_check_and_update_resource(#{id := Id, type := Type, description := NewDescription,
                               config := NewConfig}) ->
    case emqx_rule_registry:find_resource_type(Type) of
        {ok, #resource_type{on_create = {Module, Create},
                            params_spec = ParamSpec}} ->
            Config = emqx_rule_validator:validate_params(NewConfig, ParamSpec),
            case test_resource(#{type => Type, config => NewConfig}) of
                ok ->
                    _ = ?CLUSTER_CALL(init_resource, [Module, Create, Id, Config]),
                    emqx_rule_registry:add_resource(#resource{
                        id = Id,
                        type = Type,
                        config = Config,
                        description = NewDescription,
                        created_at = erlang:system_time(millisecond)
                    }),
                    ok;
               {error, Reason} ->
                    error({error, Reason})
            end
    end.

-spec(start_resource(resource_id()) -> ok | {error, Reason :: term()}).
start_resource(ResId) ->
    case emqx_rule_registry:find_resource(ResId) of
        {ok, #resource{type = ResType, config = Config}} ->
            {ok, #resource_type{on_create = {Mod, Create}}}
                = emqx_rule_registry:find_resource_type(ResType),
            try
                init_resource(Mod, Create, ResId, Config),
                refresh_actions_of_a_resource(ResId)
            catch
                throw:Reason -> {error, Reason}
            end;
        not_found ->
            {error, {resource_not_found, ResId}}
    end.

-spec(test_resource(#{type := _, config := _, _ => _}) -> ok | {error, Reason :: term()}).
test_resource(#{type := Type, config := Config0}) ->
    case emqx_rule_registry:find_resource_type(Type) of
        {ok, #resource_type{on_create = {ModC, Create},
                            on_destroy = {ModD, Destroy},
                            params_spec = ParamSpec}} ->
            Config = emqx_rule_validator:validate_params(Config0, ParamSpec),
            ResId = resource_id(),
            try
                _ = ?CLUSTER_CALL(init_resource, [ModC, Create, ResId, Config]),
                _ = ?CLUSTER_CALL(clear_resource, [ModD, Destroy, ResId]),
                ok
            catch
                throw:Reason -> {error, Reason}
            end;
        not_found ->
            {error, {resource_type_not_found, Type}}
    end.

-spec(get_resource_status(resource_id()) -> {ok, resource_status()} | {error, Reason :: term()}).
get_resource_status(ResId) ->
    case emqx_rule_registry:find_resource(ResId) of
        {ok, #resource{type = ResType}} ->
            {ok, #resource_type{on_status = {Mod, OnStatus}}}
                = emqx_rule_registry:find_resource_type(ResType),
            Status = fetch_resource_status(Mod, OnStatus, ResId),
            {ok, Status};
        not_found ->
            {error, {resource_not_found, ResId}}
    end.

-spec(get_resource_params(resource_id()) -> {ok, map()} | {error, Reason :: term()}).
get_resource_params(ResId) ->
     case emqx_rule_registry:find_resource_params(ResId) of
        {ok, #resource_params{params = Params}} ->
            {ok, Params};
        not_found ->
            {error, resource_not_initialized}
    end.

-spec(delete_resource(resource_id()) -> ok | {error, Reason :: term()}).
delete_resource(ResId) ->
    case emqx_rule_registry:find_resource(ResId) of
        {ok, #resource{type = ResType}} ->
            {ok, #resource_type{on_destroy = {ModD, Destroy}}}
                = emqx_rule_registry:find_resource_type(ResType),
            try
                case emqx_rule_registry:remove_resource(ResId) of
                    ok ->
                        _ = ?CLUSTER_CALL(clear_resource, [ModD, Destroy, ResId]),
                        ok;
                    {error, _} = R -> R
                end
            catch
                throw:Reason -> {error, Reason}
            end;
        not_found ->
            {error, not_found}
    end.

%%------------------------------------------------------------------------------
%% Re-establish resources
%%------------------------------------------------------------------------------

-spec(refresh_resources() -> ok).
refresh_resources() ->
    lists:foreach(fun refresh_resource/1,
                  emqx_rule_registry:get_resources()).

refresh_resource(Type) when is_atom(Type) ->
    lists:foreach(fun refresh_resource/1,
                  emqx_rule_registry:get_resources_by_type(Type));

refresh_resource(#resource{id = ResId, type = Type, config = Config}) ->
    try
        {ok, #resource_type{on_create = {M, F}}} =
            emqx_rule_registry:find_resource_type(Type),
        ok = emqx_rule_engine:init_resource(M, F, ResId, Config)
    catch _:_ ->
        emqx_rule_monitor:ensure_resource_retrier(ResId, ?T_RETRY)
    end.

-spec(refresh_rules() -> ok).
refresh_rules() ->
    lists:foreach(fun
        (#rule{enabled = true} = Rule) ->
            try refresh_rule(Rule)
            catch _:_ ->
                emqx_rule_registry:add_rule(Rule#rule{enabled = false, state = refresh_failed_at_bootup})
            end;
        (_) -> ok
    end, emqx_rule_registry:get_rules()).

refresh_rule(#rule{id = RuleId, for = Topics, actions = Actions}) ->
    ok = emqx_rule_metrics:create_rule_metrics(RuleId),
    lists:foreach(fun emqx_rule_events:load/1, Topics),
    refresh_actions(Actions).

-spec(refresh_resource_status() -> ok).
refresh_resource_status() ->
    lists:foreach(
        fun(#resource{id = ResId, type = ResType}) ->
            case emqx_rule_registry:find_resource_type(ResType) of
                {ok, #resource_type{on_status = {Mod, OnStatus}}} ->
                    _ = fetch_resource_status(Mod, OnStatus, ResId);
                _ -> ok
            end
        end, emqx_rule_registry:get_resources()).

%%------------------------------------------------------------------------------
%% Internal Functions
%%------------------------------------------------------------------------------
prepare_actions(Actions, NeedInit) ->
    [prepare_action(Action, NeedInit) || Action <- Actions].

prepare_action(#{name := Name, args := Args0} = Action, NeedInit) ->
    case emqx_rule_registry:find_action(Name) of
        {ok, #action{module = Mod, on_create = Create, params_spec = ParamSpec}} ->
            Args = emqx_rule_validator:validate_params(Args0, ParamSpec),
            ActionInstId = maps:get(id, Action, action_instance_id(Name)),
            case NeedInit of
                true ->
                    _ = ?CLUSTER_CALL(init_action, [Mod, Create, ActionInstId,
                            with_resource_params(Args)]),
                    ok;
                false -> ok
            end,
            #action_instance{
                id = ActionInstId, name = Name, args = Args,
                fallbacks = prepare_actions(maps:get(fallbacks, Action, []), NeedInit)
            };
        not_found ->
            throw({action_not_found, Name})
    end.

with_resource_params(Args = #{<<"$resource">> := ResId}) ->
    case emqx_rule_registry:find_resource_params(ResId) of
        {ok, #resource_params{params = Params}} ->
            maps:merge(Args, Params);
        not_found ->
            throw({resource_not_initialized, ResId})
    end;
with_resource_params(Args) -> Args.

-dialyzer([{nowarn_function, may_update_rule_params/2}]).
may_update_rule_params(Rule, Params = #{rawsql := SQL}) ->
    case emqx_rule_sqlparser:parse_select(SQL) of
        {ok, Select} ->
            may_update_rule_params(
                Rule#rule{
                    rawsql = SQL,
                    for = emqx_rule_sqlparser:select_from(Select),
                    is_foreach = emqx_rule_sqlparser:select_is_foreach(Select),
                    fields = emqx_rule_sqlparser:select_fields(Select),
                    doeach = emqx_rule_sqlparser:select_doeach(Select),
                    incase = emqx_rule_sqlparser:select_incase(Select),
                    conditions = emqx_rule_sqlparser:select_where(Select)
                },
                maps:remove(rawsql, Params));
        Reason -> throw(Reason)
    end;
may_update_rule_params(Rule = #rule{enabled = OldEnb, actions = Actions, state = OldState},
         Params = #{enabled := NewEnb}) ->
    State = case {OldEnb, NewEnb} of
        {false, true} ->
            refresh_rule(Rule),
            force_changed;
        {true, false} ->
            clear_actions(Actions),
            force_changed;
        _NoChange -> OldState
    end,
    may_update_rule_params(Rule#rule{enabled = NewEnb, state = State}, maps:remove(enabled, Params));
may_update_rule_params(Rule, Params = #{description := Descr}) ->
    may_update_rule_params(Rule#rule{description = Descr}, maps:remove(description, Params));
may_update_rule_params(Rule, Params = #{on_action_failed := OnFailed}) ->
    may_update_rule_params(Rule#rule{on_action_failed = OnFailed},
        maps:remove(on_action_failed, Params));
may_update_rule_params(Rule = #rule{actions = OldActions}, Params = #{actions := Actions}) ->
    %% prepare new actions before removing old ones
    NewActions = prepare_actions(Actions, maps:get(enabled, Params, true)),
    _ = ?CLUSTER_CALL(clear_actions, [OldActions]),
    may_update_rule_params(Rule#rule{actions = NewActions}, maps:remove(actions, Params));
may_update_rule_params(Rule, _Params) -> %% ignore all the unsupported params
    Rule.

ignore_lib_apps(Apps) ->
    LibApps = [kernel, stdlib, sasl, appmon, eldap, erts,
               syntax_tools, ssl, crypto, mnesia, os_mon,
               inets, goldrush, gproc, runtime_tools,
               snmp, otp_mibs, public_key, asn1, ssh, hipe,
               common_test, observer, webtool, xmerl, tools,
               test_server, compiler, debugger, eunit, et,
               wx],
    [AppName || {AppName, _, _} <- Apps, not lists:member(AppName, LibApps)].

resource_id() ->
    gen_id("resource:", fun emqx_rule_registry:find_resource/1).

rule_id() ->
    gen_id("rule:", fun emqx_rule_registry:get_rule/1).

gen_id(Prefix, TestFun) ->
    Id = iolist_to_binary([Prefix, emqx_rule_id:gen()]),
    case TestFun(Id) of
        not_found -> Id;
        _Res -> gen_id(Prefix, TestFun)
    end.

action_instance_id(ActionName) ->
    iolist_to_binary([atom_to_list(ActionName), "_", integer_to_list(erlang:system_time())]).

init_resource(Module, OnCreate, ResId, Config) ->
    Params = ?RAISE(Module:OnCreate(ResId, Config),
        {{Module, OnCreate}, {_EXCLASS_, _EXCPTION_, _ST_}}),
    ResParams = #resource_params{id = ResId,
                                 params = Params,
                                 status = #{is_alive => true}},
    emqx_rule_registry:add_resource_params(ResParams).

init_action(Module, OnCreate, ActionInstId, Params) ->
    ok = emqx_rule_metrics:create_metrics(ActionInstId),
    case ?RAISE(Module:OnCreate(ActionInstId, Params),
                {{init_action_failure, node()},
                 {{Module, OnCreate}, {_EXCLASS_, _EXCPTION_, _ST_}}}) of
        {Apply, NewParams} when is_function(Apply) -> %% BACKW: =< e4.2.2
            ok = emqx_rule_registry:add_action_instance_params(
                #action_instance_params{id = ActionInstId, params = NewParams, apply = Apply});
        {Bindings, NewParams} when is_list(Bindings) ->
            ok = emqx_rule_registry:add_action_instance_params(
            #action_instance_params{
                id = ActionInstId, params = NewParams,
                apply = #{mod => Module, bindings => maps:from_list(Bindings)}});
        Apply when is_function(Apply) -> %% BACKW: =< e4.2.2
            ok = emqx_rule_registry:add_action_instance_params(
                #action_instance_params{id = ActionInstId, params = Params, apply = Apply})
    end.

clear_resource(_Module, undefined, ResId) ->
    ok = emqx_rule_registry:remove_resource_params(ResId);
clear_resource(Module, Destroy, ResId) ->
    case emqx_rule_registry:find_resource_params(ResId) of
        {ok, #resource_params{params = Params}} ->
            ?RAISE(Module:Destroy(ResId, Params),
                   {{destroy_resource_failure, node()}, {{Module, Destroy}, {_EXCLASS_,_EXCPTION_,_ST_}}}),
            ok = emqx_rule_registry:remove_resource_params(ResId);
        not_found ->
            ok
    end.

clear_rule(#rule{id = RuleId, actions = Actions}) ->
    clear_actions(Actions),
    emqx_rule_metrics:clear_rule_metrics(RuleId),
    ok.

clear_actions(Actions) ->
    lists:foreach(
        fun(#action_instance{id = Id, name = ActName, fallbacks = Fallbacks}) ->
            {ok, #action{module = Mod, on_destroy = Destory}} = emqx_rule_registry:find_action(ActName),
            clear_action(Mod, Destory, Id),
            clear_actions(Fallbacks)
        end, Actions).

clear_action(_Module, undefined, ActionInstId) ->
    emqx_rule_metrics:clear_metrics(ActionInstId),
    ok = emqx_rule_registry:remove_action_instance_params(ActionInstId);
clear_action(Module, Destroy, ActionInstId) ->
    case erlang:function_exported(Module, Destroy, 2) of
        true ->
            emqx_rule_metrics:clear_metrics(ActionInstId),
            case emqx_rule_registry:get_action_instance_params(ActionInstId) of
                {ok, #action_instance_params{params = Params}} ->
                    ?RAISE(Module:Destroy(ActionInstId, Params),{{destroy_action_failure, node()},
                                                {{Module, Destroy}, {_EXCLASS_,_EXCPTION_,_ST_}}}),
                    ok = emqx_rule_registry:remove_action_instance_params(ActionInstId);
                not_found ->
                    ok
            end;
        false -> ok
    end.

fetch_resource_status(Module, OnStatus, ResId) ->
    case emqx_rule_registry:find_resource_params(ResId) of
        {ok, ResParams = #resource_params{params = Params, status = #{is_alive := LastIsAlive}}} ->
            NewStatus = try
                case Module:OnStatus(ResId, Params) of
                    #{is_alive := LastIsAlive} = Status -> Status;
                    #{is_alive := true} = Status ->
                        {ok, Type} = find_type(ResId),
                        Name = alarm_name_of_resource_down(Type, ResId),
                        emqx_alarm:deactivate(Name),
                        Status;
                    #{is_alive := false} = Status ->
                        {ok, Type} = find_type(ResId),
                        Name = alarm_name_of_resource_down(Type, ResId),
                        emqx_alarm:activate(Name, #{id => ResId, type => Type}),
                        Status
                end
            catch _Error:Reason:STrace ->
                ?LOG(error, "get resource status for ~p failed: ~0p", [ResId, {Reason, STrace}]),
                #{is_alive => false}
            end,
            emqx_rule_registry:add_resource_params(ResParams#resource_params{status = NewStatus}),
            NewStatus;
        not_found ->
            #{is_alive => false}
    end.

refresh_actions_of_a_resource(ResId) ->
    R = fun (#action_instance{args = #{<<"$resource">> := ResId0}})
                when ResId0 =:= ResId -> true;
            (_) -> false
        end,
    F = fun(#rule{actions = Actions}) -> refresh_actions(Actions, R) end,
    lists:foreach(F, emqx_rule_registry:get_rules()).

refresh_actions(Actions) ->
    refresh_actions(Actions, fun(_) -> true end).
refresh_actions(Actions, Pred) ->
    lists:foreach(
        fun(#action_instance{args = Args,
                             id = Id, name = ActName,
                             fallbacks = Fallbacks} = ActionInst) ->
            case Pred(ActionInst) of
                true ->
                    {ok, #action{module = Mod, on_create = Create}}
                        = emqx_rule_registry:find_action(ActName),
                    _ = ?CLUSTER_CALL(init_action, [Mod, Create, Id, with_resource_params(Args)]),
                    refresh_actions(Fallbacks, Pred);
                false -> ok
            end
        end, Actions).

find_type(ResId) ->
    {ok, #resource{type = Type}} = emqx_rule_registry:find_resource(ResId),
    {ok, Type}.

alarm_name_of_resource_down(Type, ResId) ->
    list_to_binary(io_lib:format("resource/~s/~s/down", [Type, ResId])).

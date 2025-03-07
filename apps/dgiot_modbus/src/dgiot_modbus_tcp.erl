%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 DGIOT Technologies Co., Ltd. All Rights Reserved.
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
-module(dgiot_modbus_tcp).
-author("stoneliu").
-include("dgiot_modbus.hrl").
-include_lib("dgiot/include/dgiot_socket.hrl").
-include_lib("dgiot/include/logger.hrl").

-define(MAX_BUFF_SIZE, 1024).

-export([
    get_deviceid/2,
    start/2
]).

%% TCP callback
-export([init/1, handle_info/2, handle_cast/2, handle_call/3, terminate/2, code_change/3]).

start(Port, State) ->
    dgiot_tcp_server:child_spec(?MODULE, dgiot_utils:to_int(Port), State).

%% =======================
%% {ok, State} | {stop, Reason}
%%init(TCPState) ->
%%    erlang:send_after(5 * 1000, self(), login),.
%%    {ok, TCPState}.

init(#tcp{state = #state{id = ChannelId}} = TCPState) ->
    case dgiot_bridge:get_products(ChannelId) of
        {ok, _TYPE, _ProductIds} ->
            {ok, TCPState};
        {error, not_find} ->
            {stop, not_find_channel}
    end.

%% 9C A5 25 CD 00 DB
%% 11 04 02 06 92 FA FE
handle_info({tcp, Buff}, #tcp{socket = Socket, state = #state{id = ChannelId, devaddr = <<>>, head = Head, len = Len, product = ProductId, dtutype = Dtutype} = State} = TCPState) ->
    DTUIP = dgiot_utils:get_ip(Socket),
    DtuAddr = dgiot_utils:binary_to_hex(Buff),
    List = dgiot_utils:to_list(DtuAddr),
    List1 = dgiot_utils:to_list(Buff),
    #{<<"objectId">> := DeviceId} =
        dgiot_parse:get_objectid(<<"Device">>, #{<<"product">> => ProductId, <<"devaddr">> => DtuAddr}),
    case re:run(DtuAddr, Head, [{capture, first, list}]) of
        {match, [Head]} when length(List) == Len ->
            {DevId, Devaddr} =
                case create_device(DeviceId, ProductId, DtuAddr, DTUIP, Dtutype) of
                    {<<>>, <<>>} ->
                        {<<>>, <<>>};
                    {DevId1, Devaddr1} ->
                        {DevId1, Devaddr1}
                end,
            Topic = <<"profile/", ProductId/binary, "/", Devaddr/binary>>,
            dgiot_bridge:send_log(ChannelId, ProductId, Devaddr, "DTU revice from  ~p", [dgiot_utils:binary_to_hex(Buff)]),
            dgiot_mqtt:subscribe(Topic),
            {noreply, TCPState#tcp{buff = <<>>, register = true, clientid = DevId, state = State#state{devaddr = Devaddr, deviceId = DevId}}};
        _Error ->
            case re:run(Buff, Head, [{capture, first, list}]) of
                {match, [Head]} when length(List1) == Len ->
                    create_device(DeviceId, ProductId, Buff, DTUIP, Dtutype),
                    Topic = <<"profile/", ProductId/binary, "/", Buff/binary>>,
                    dgiot_bridge:send_log(ChannelId, ProductId, Buff, "DTU revice from  ~p", [dgiot_utils:binary_to_hex(Buff)]),
                    dgiot_mqtt:subscribe(Topic),
                    {noreply, TCPState#tcp{buff = <<>>, state = State#state{devaddr = Buff}}};
                Error1 ->
                    ?LOG(info, "Error1 ~p Buff ~p ", [Error1, dgiot_utils:to_list(Buff)]),
                    {noreply, TCPState#tcp{buff = <<>>}}
            end
    end;

handle_info({tcp, Buff}, #tcp{state = #state{id = ChannelId, devaddr = DtuAddr, env = #{product := ProductId, pn := Pn, di := Di}, product = DtuProductId} = State} = TCPState) ->
    dgiot_bridge:send_log(ChannelId, ProductId, DtuAddr, "DtuAddr ~p revice from  ~p", [DtuAddr, dgiot_utils:binary_to_hex(Buff)]),
    <<H:8, L:8>> = dgiot_utils:hex_to_binary(modbus_rtu:is16(Di)),
    <<Sh:8, Sl:8>> = dgiot_utils:hex_to_binary(modbus_rtu:is16(Pn)),
    case modbus_rtu:parse_frame(Buff, [], #{
        <<"dtuproduct">> => ProductId,
        <<"channel">> => ChannelId,
        <<"dtuaddr">> => DtuAddr,
        <<"slaveId">> => Sh * 256 + Sl,
        <<"address">> => H * 256 + L}) of
        {_, Things} ->
%%            ?LOG(info, "Things ~p", [Things]),
            NewTopic = <<"thing/", DtuProductId/binary, "/", DtuAddr/binary, "/post">>,
            dgiot_bridge:send_log(ChannelId, ProductId, DtuAddr, "DtuAddr ~p end to_task: ~p: ~p ~n", [DtuAddr, NewTopic, jsx:encode(Things)]),
            DeviceId = dgiot_parse:get_deviceid(ProductId, DtuAddr),
            dgiot_mqtt:publish(DeviceId, NewTopic, jsx:encode(Things));
        Other ->
            ?LOG(info, "Other ~p", [Other]),
            pass
    end,
    {noreply, TCPState#tcp{buff = <<>>, state = State#state{env = <<>>}}};

handle_info({deliver, _, Msg}, #tcp{state = #state{id = ChannelId} = State} = TCPState) ->
    Payload = dgiot_mqtt:get_payload(Msg),
    Topic = dgiot_mqtt:get_topic(Msg),
    case jsx:is_json(Payload) of
        true ->
            case binary:split(Topic, <<$/>>, [global, trim]) of
                [<<"profile">>, ProductId, DtuAddr] ->
%%                    设置参数
                    case Payload of
                        #{<<"_dgiotprotocol">> := <<"modbus">>} ->
                            Payloads = modbus_rtu:set_params(maps:without([<<"_dgiotprotocol">>], Payload), ProductId, DtuAddr),
                            lists:map(fun(X) ->
                                dgiot_tcp_server:send(TCPState, X)
                                      end, Payloads);
                        _ ->
                            pass
                    end,
                    {noreply, TCPState};
                [<<"thing">>, _ProductId, DevAddr] ->
                    [#{<<"thingdata">> := ThingData} | _] = jsx:decode(Payload, [{labels, binary}, return_maps]),
%%                    ?LOG(error, "ThingData ~p", [ThingData]),
                    case ThingData of
                        #{<<"command">> := <<"r">>,
                            <<"data">> := Value,
                            <<"di">> := Di,
                            <<"pn">> := SlaveId,
                            <<"product">> := ProductId,
                            <<"protocol">> := <<"modbus">>
                        } ->
                            Datas = modbus_rtu:to_frame(#{
                                <<"addr">> => SlaveId,
                                <<"value">> => Value,
                                <<"productid">> => ProductId,
                                <<"di">> => Di}),
%%                            ?LOG(error, "Datas ~p", [Datas]),
                            lists:map(fun(X) ->
                                dgiot_bridge:send_log(ChannelId, ProductId, DevAddr, " to_device: ~p [~p] ", [DevAddr, dgiot_utils:binary_to_hex(X)]),
                                dgiot_tcp_server:send(TCPState, X),
                                timer:sleep(1000)
                                      end, Datas),
                            {noreply, TCPState#tcp{state = State#state{env = #{product => ProductId, pn => SlaveId, di => Di}}}};
                        #{<<"command">> := <<"rw">>,
                            <<"data">> := Value,
                            <<"di">> := Di,
                            <<"pn">> := SlaveId,
                            <<"product">> := ProductId,
                            <<"protocol">> := <<"modbus">>
                        } ->
                            Datas = modbus_rtu:to_frame(#{
                                <<"addr">> => SlaveId,
                                <<"value">> => Value,
                                <<"productid">> => ProductId,
                                <<"di">> => Di}),
%%                    ?LOG(error, "Datas ~p", [Datas]),
                            lists:map(fun(X) ->
                                dgiot_bridge:send_log(ChannelId, ProductId, DevAddr, "to_device: ~p [~p] ", [DevAddr, dgiot_utils:binary_to_hex(X)]),
                                dgiot_tcp_server:send(TCPState, X),
                                timer:sleep(1000)
                                      end, Datas),
                            {noreply, TCPState#tcp{state = State#state{env = #{product => ProductId, pn => SlaveId, di => Di}}}};
                        _Ot ->
                            ?LOG(error, "_Ot ~p", [_Ot]),
                            {noreply, TCPState}
                    end;
                _Other ->
                    ?LOG(error, "_Other ~p", [_Other]),
                    {noreply, TCPState}
            end;
        false ->
            case binary:split(Topic, <<$/>>, [global, trim]) of
                [<<"profile">>, ProductId, DevAddr] ->
                    %% 设置参数
                    case Payload of
                        #{<<"_dgiotprotocol">> := <<"modbus">>} ->
                            Payloads = modbus_rtu:set_params(maps:without([<<"_dgiotprotocol">>], Payload), ProductId, DevAddr),
                            lists:map(fun(X) ->
                                dgiot_bridge:send_log(ChannelId, ProductId, DevAddr, "to_device: ~p [~p] ", [DevAddr, dgiot_utils:binary_to_hex(X)]),
                                dgiot_tcp_server:send(TCPState, X)
                                      end, Payloads);
                        _ ->
                            pass
                    end,
                    {noreply, TCPState};
                _ ->
                    {noreply, TCPState}
            end
    end;
%% {stop, TCPState} | {stop, Reason} | {ok, TCPState} | ok | stop
handle_info(_Info, TCPState) ->
    ?LOG(info, "TCPState ~p", [TCPState]),
    {noreply, TCPState}.

handle_call(_Msg, _From, TCPState) ->
    {reply, ok, TCPState}.

handle_cast(_Msg, TCPState) ->
    {noreply, TCPState}.

terminate(_Reason, _TCPState) ->
    ok.

code_change(_OldVsn, TCPState, _Extra) ->
    {ok, TCPState}.

get_deviceid(ProdcutId, DevAddr) ->
    #{<<"objectId">> := DeviceId} =
        dgiot_parse:get_objectid(<<"Device">>, #{<<"product">> => ProdcutId, <<"devaddr">> => DevAddr}),
    DeviceId.

create_device(DeviceId, ProductId, DTUMAC, DTUIP, Dtutype) ->
    case dgiot_parse:get_object(<<"Product">>, ProductId) of
        {ok, #{<<"ACL">> := Acl, <<"devType">> := DevType}} ->
            case dgiot_parse:get_object(<<"Device">>, DeviceId) of
                {ok, #{<<"devaddr">> := _GWAddr}} ->
                    dgiot_parse:update_object(<<"Device">>, DeviceId, #{<<"ip">> => DTUIP, <<"status">> => <<"ONLINE">>}),
                    dgiot_task:save_pnque(ProductId, DTUMAC, ProductId, DTUMAC),
                    create_instruct(Acl, ProductId, DeviceId);
                _ ->
                    dgiot_device:create_device(#{
                        <<"devaddr">> => DTUMAC,
                        <<"name">> => <<Dtutype/binary, DTUMAC/binary>>,
                        <<"ip">> => DTUIP,
                        <<"isEnable">> => true,
                        <<"product">> => ProductId,
                        <<"ACL">> => Acl,
                        <<"status">> => <<"ONLINE">>,
                        <<"location">> => #{<<"__type">> => <<"GeoPoint">>, <<"longitude">> => 120.161324, <<"latitude">> => 30.262441},
                        <<"brand">> => Dtutype,
                        <<"devModel">> => DevType
                    }),
                    dgiot_task:save_pnque(ProductId, DTUMAC, ProductId, DTUMAC),
                    create_instruct(Acl, ProductId, DeviceId)
            end,
            Productname =
                case dgiot_parse:get_object(<<"Product">>, ProductId) of
                    {ok, #{<<"name">> := Productname1}} ->
                        Productname1;
                    _ ->
                        <<"">>
                end,
            ?MLOG(info, #{<<"clientid">> => DeviceId, <<"devaddr">> => DTUMAC, <<"productid">> => ProductId, <<"productname">> => Productname, <<"devicename">> => <<Dtutype/binary, DTUMAC/binary>>, <<"status">> => <<"上线"/utf8>>}, ['device_statuslog']),
            {DeviceId, DTUMAC};
        Error2 ->
            ?LOG(info, "Error2 ~p ", [Error2]),
            {<<>>, <<>>}
    end.

create_instruct(ACL, DtuProductId, DtuDevId) ->
    case dgiot_product:lookup_prod(DtuProductId) of
        {ok, #{<<"thing">> := #{<<"properties">> := Properties}}} ->
            lists:map(fun(Y) ->
                case Y of
                    #{<<"dataForm">> := #{<<"slaveid">> := 256}} ->   %%不做指令
                        pass;
                    #{<<"dataForm">> := #{<<"slaveid">> := SlaveId}} ->
                        Pn = dgiot_utils:to_binary(SlaveId),
%%                        ?LOG(info,"DtuProductId ~p DtuDevId ~p Pn ~p ACL ~p", [DtuProductId, DtuDevId, Pn, ACL]),
%%                        ?LOG(info,"Y ~p", [Y]),
                        dgiot_instruct:create(DtuProductId, DtuDevId, Pn, ACL, <<"all">>, #{<<"properties">> => [Y]});
                    _ -> pass
                end
                      end, Properties);
        _ -> pass
    end.

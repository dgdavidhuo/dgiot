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

-module(dgiot_evidence).
-author("johnliu").
-include_lib("dgiot/include/logger.hrl").
-export([init/1, description/0
]).

-export([
    post/1,
    put/2,
    get/2,
    get_ukey/0,
    signData/1,
    verifySignData/3,
    readCert/0
]).

-export([
    upload/3,
    upload/2,
    create_report/7,
    get_capture/1,
    get_report_package/6,
    post_data/2,
    get_filehome/1,
    test/0
]).

%%--------------------------------------------------------------------
%% Auth Module Callbacks
%%--------------------------------------------------------------------

init({}) ->
    {ok, #{}}.

description() -> "dgiot evidence".

get_ukey() ->
    Bin = unicode:characters_to_binary(os:cmd("chcp 65001 && dgiot_ukey.exe readUkey default")),
    <<"Active code page: 65001\r\n", Json/binary>> = Bin,
    case jsx:is_json(Json) of
        true ->
            #{<<"data">> := Data} = jsx:decode(Json, [{labels, binary}, return_maps]),
            case Data of
                #{<<"ukey">> := Ukey} ->
                    Ukey;
                _ -> <<"">>
            end;
        false -> <<"">>
    end.

signData(Data) ->
    DataList = "dgiotdsdfsfsdf" ++ dgiot_utils:to_list(Data) ++ "2020s88jsdfsddmmgg",
    Bin = unicode:characters_to_binary(os:cmd("chcp 65001 && dgiot_ukey.exe signData default " ++ DataList)),
    <<"Active code page: 65001\r\n", Json/binary>> = Bin,
    jsx:decode(Json, [{labels, binary}, return_maps]).

verifySignData(Ukey, Data, SignData) ->
    UkeyList = dgiot_utils:to_list(Ukey),
    DataList = "dgiotdsdfsfsdf" ++ dgiot_utils:to_list(Data) ++ "2020s88jsdfsddmmgg",
    SignDataList = dgiot_utils:to_list(SignData),
    Bin = unicode:characters_to_binary(os:cmd("chcp 65001 && dgiot_ukey.exe verifySignData " ++
        UkeyList ++ " " ++ DataList ++ " " ++ SignDataList)),
    <<"Active code page: 65001\r\n", Json/binary>> = Bin,
    jsx:decode(Json, [{labels, binary}, return_maps]).

readCert() ->
    {file, _Here} = code:is_loaded(?MODULE),
    Bin = unicode:characters_to_binary(os:cmd("chcp 65001 && dgiot_ukey.exe readCert default")),
    <<"Active code page: 65001\r\n", Json/binary>> = Bin,
    case jsx:is_json(Json) of
        true ->
            #{<<"data">> := Data} = jsx:decode(Json, [{labels, binary}, return_maps]),
            {ok, Data};
        false -> {error, Json}
    end.

put(#{<<"objectId">> := ObjectId, <<"status">> := Status}, SessionToken) ->
    case dgiot_parse:get_object(<<"Evidence">>, ObjectId,
        [{"X-Parse-Session-Token", SessionToken}], [{from, rest}]) of
        {ok, #{<<"original">> := Original}} ->
            dgiot_parse:update_object(<<"Evidence">>, ObjectId, #{<<"original">> => Original#{
                <<"status">> => Status}},
                [{"X-Parse-Session-Token", SessionToken}], [{from, rest}]);
        Error -> Error
    end;

put(#{<<"reportId">> := ReportId, <<"type">> := Type, <<"status">> := Status}, SessionToken) ->
    ReportIds =
        case Type of
            <<"single">> ->
                [ReportId];
            _ ->
                case dgiot_parse:query_object(<<"Device">>, #{<<"where">> => #{<<"parentId">> => ReportId}
                }, [{"X-Parse-Session-Token", SessionToken}], [{from, rest}]) of
                    {ok, #{<<"results">> := Results}} ->
                        lists:foldl(fun(#{<<"objectId">> := ObjectId}, Acc) ->
                            Acc ++ [ObjectId]
                                    end, [ReportId], Results);
                    _ -> []
                end
        end,
    case dgiot_parse:query_object(<<"Evidence">>, #{<<"where">> => #{<<"reportId">> => #{<<"$in">> => ReportIds}}},
        [{"X-Parse-Session-Token", SessionToken}], [{from, rest}]) of
        {ok, #{<<"results">> := Results1}} ->
            Batch = lists:foldl(fun(#{<<"objectId">> := ObjectId, <<"original">> := Original}, Acc) ->
                Acc ++ [
                    #{
                        <<"method">> => <<"PUT">>,
                        <<"path">> => <<"/classes/Evidence/", ObjectId/binary>>,
                        <<"body">> => #{<<"original">> => Original#{<<"status">> => Status}}}
                ]
                                end, [], Results1),
            dgiot_parse:batch(Batch, [{"X-Parse-Session-Token", SessionToken}], [{from, rest}]);
        Error -> Error
    end.

get(#{<<"reportId">> := ReportId}, SessionToken) ->
    ReportIds =
        case dgiot_parse:get_object(<<"Device">>, ReportId, [{"X-Parse-Session-Token", SessionToken}], [{from, rest}]) of
            {ok, #{<<"parentId">> := _ParentId}} ->
                [ReportId];
            _ ->
                case dgiot_parse:query_object(<<"Device">>, #{<<"where">> => #{<<"parentId">> => ReportId}}, [{"X-Parse-Session-Token", SessionToken}], [{from, rest}]) of
                    {ok, #{<<"results">> := Results}} ->
                        lists:foldl(fun(#{<<"objectId">> := ObjectId}, Acc) ->
                            Acc ++ [ObjectId]
                                    end, [ReportId], Results);
                    _ -> []
                end
        end,
%%    ?LOG(info,"ReportIds ~p", [ReportIds]),
    Filter = #{<<"where">> => #{<<"reportId">> => #{<<"$in">> => ReportIds}}, <<"keys">> => [<<"reportId">>, <<"original">>]},
%%    ?LOG(info,"Filter ~p", [Filter]),
    case dgiot_parse:query_object(<<"Evidence">>, Filter, [{"X-Parse-Session-Token", SessionToken}], [{from, rest}]) of
        {ok, #{<<"results">> := Results1}} ->
%%            ?LOG(info,"Results1 ~p", [Results1]),
            R = lists:foldl(fun(#{<<"reportId">> := ReportId1, <<"original">> := Original}, Acc) ->
                Status = maps:get(<<"status">>, Original, <<"未审核"/utf8>>),
                Statistics = maps:get(ReportId1, Acc, #{}),
                AllStatistics = maps:get(<<"total">>, Acc, #{}),
                Num = maps:get(Status, Statistics, 0) + 1,
                AllNum = maps:get(Status, AllStatistics, 0) + 1,
                Acc#{
                    ReportId1 => Statistics#{Status => Num},
                    <<"total">> => AllStatistics#{Status => AllNum}
                }
                            end, #{}, Results1),
            {ok, #{<<"results">> => R}};
        Error -> Error
    end.



post(#{<<"id">> := ReportId, <<"scene">> := Scene, <<"md5">> := Md5, <<"original">> := Original,
    <<"sessionToken">> := SessionToken}) ->
    Map = signData(Md5),
    #{
        <<"timestamp">> := Timestamp,
        <<"cmd">> := <<"signData">>,
        <<"data">> := #{<<"ukey">> := UKey, <<"SignData">> := SignData}
    } = Map,
    case UKey == <<>> orelse SignData == <<>> of
        true ->
            {error, <<"SignData Fail">>};
        false ->
            case dgiot_auth:get_session(SessionToken) of
                #{<<"roles">> := Roles} = _User ->
                    [#{<<"name">> := Role} | _] = maps:values(Roles),
                    Evidence = #{
                        <<"ACL">> => #{<<"role:", Role/binary>> => #{
                            <<"read">> => true,
                            <<"write">> => true}
                        },
                        <<"reportId">> => ReportId,
                        <<"scene">> => Scene,
                        <<"original">> => Original#{<<"status">> => <<"未审核"/utf8>>},
                        <<"md5">> => Md5,
                        <<"timestamp">> => Timestamp,
                        <<"ukey">> => UKey,
                        <<"signData">> => SignData
                    },
                    dgiot_parse:create_object(<<"Evidence">>, Evidence);
                _ -> {error, <<"SignData Fail">>}
            end
    end;

post(R) ->
    ?LOG(info, "R ~p ", [R]).

post_data(Class, FilePath) ->
    ?LOG(info, "Class ~p, FilePath ~p", [Class, FilePath]),
    case file:read_file(FilePath) of
        {ok, Bin} ->
            case catch jsx:decode(Bin, [{labels, binary}, return_maps]) of
                {'EXIT', Reason} ->
                    ?LOG(info, "Reason ~p", [Reason]),
                    {error, Reason};
                Data ->
                    Datas = lists:foldl(fun(X, Acc) ->
                        Acc ++ [maps:without([<<"tag">>, <<"updatedAt">>, <<"createdAt">>, <<"children">>], X)]
                                        end, [], Data),
                    Fun =
                        fun(Res, Acc) ->
                            ?LOG(info, "Res ~p", [Res]),
                            lists:concat([Acc, Res])
                        end,
                    case dgiot_parse:import(Class, Datas, 5000, Fun, []) of
                        {error, Reason1} ->
                            ?LOG(info, "Reason1 ~p", [Reason1]),
                            {error, Reason1};
                        Result ->
                            {ok, Result}
                    end
            end;
        {error, Reason2} ->
            ?LOG(info, "Reason2 ~p", [Reason2]),
            {error, Reason2}
    end.

get_report_package(ReportId, Devices, Products, Evidence, Files, SessionToken) ->
    case dgiot_parse:query_object(<<"_Role">>, #{
        <<"keys">> => [<<"name">>, <<"tag">>],
        <<"limit">> => 1}, [{"X-Parse-Session-Token", SessionToken}], [{from, rest}]) of
        {ok, #{<<"results">> := [#{<<"name">> := AppName, <<"tag">> := #{<<"appconfig">> := Config}} | _]}} ->
            Root = get_filehome(unicode:characters_to_list(maps:get(<<"home">>, Config, <<"D:/dgiot/dgiot_data_center/datacenter/file/files">>))),
            FileServer = unicode:characters_to_list(maps:get(<<"file">>, Config, <<"http://127.0.0.1:1250/shapes/upload">>)),
            Url = string:sub_string(FileServer, 1, string:rchr(FileServer, $/)),
            Now = dgiot_datetime:nowstamp(),
            ListNow = binary_to_list(dgiot_utils:to_binary(Now)),
            AppList = unicode:characters_to_list(AppName),
            Zipfile = unicode:characters_to_list(ReportId) ++ ".zip",
            ZipRoot = Root ++ "/" ++ AppList ++ "/" ++ ListNow,
            file:make_dir(ZipRoot),
            ?LOG(info, "ZipRoot ~p", [ZipRoot]),
            file:write_file(ZipRoot ++ "/Device.json", jsx:encode(Devices)),
            file:write_file(ZipRoot ++ "/Product.json", jsx:encode(Products)),
            file:write_file(ZipRoot ++ "/Evidence.json", jsx:encode(Evidence)),
            FileList = lists:foldl(fun(X, Acc) ->
                [_, _Group, FileApp, FileName] = re:split(X, <<"/">>),
                Acc ++ [{FileApp, FileName}]
                                   end, [], Files),
            lists:map(fun({FileApp, FileName1}) ->
                FileAppList = unicode:characters_to_list(FileApp),
                FileNameList = unicode:characters_to_list(FileName1),
                ZipApp = ZipRoot ++ "/" ++ FileAppList,
                file:make_dir(ZipApp),
                SrcFile = Root ++ "/" ++ FileAppList ++ "/" ++ FileNameList,
                DestFile = ZipRoot ++ "/" ++ FileAppList ++ "/" ++ FileNameList,
                file:copy(SrcFile, DestFile)
                      end, FileList),
            DestPath = Root ++ "/" ++ AppList ++ "/" ++ Zipfile,
            Cmd = case os:type() of
                      {win32, _} -> "chcp 65001 && dgiot_zip zippath " ++ DestPath ++ " " ++ ZipRoot;
                      _ -> "zip  " ++ DestPath ++ " " ++ ZipRoot
                  end,
            ?LOG(info, "DestPath ~p Url ~p", [DestPath, Url]),
            os:cmd(Cmd),
            NewUrl = unicode:characters_to_binary(Url ++ AppList ++ "/" ++ Zipfile),
            ?LOG(info, "NewUrl ~p", [NewUrl]),
            {ok, #{
                <<"url">> => NewUrl
            }};
        _ -> {error, <<"not find">>}
    end.

get_filehome(HomePath) ->
    Path = dgiot_utils:to_binary(lists:reverse(dgiot_utils:to_list(HomePath))),
    NewPath = case Path of
                  <<"//", Path1/binary>> -> Path1;
                  <<"/", Path2/binary>> -> Path2;
                  <<"\\", Path3/binary>> -> Path3;
                  Path4 -> Path4
              end,
    lists:reverse(dgiot_utils:to_list(NewPath)).

test() ->
%%    <<"Active code page: 65001\r\nCapacity    \r\r\n8589934592    \r\r\899999999">>.
    trim_string("8589934592   ").


trim_string(Str) when is_binary(Str) ->
    trim_string(Str, binary);
trim_string(Str) when is_list(Str) ->
    trim_string(Str, list).

trim_string(Str, Ret) ->
    re:replace(Str, "^[\s\x{3000}]+|[\s\x{3000}]+$", "", [global, {return, Ret}, unicode]).

%% "{\"url\":\"http://192.168.2.7:1250/shapes/pump/a0_bd_1d_ce_8d_a7_1591271470.mp4\",
%% \"md5\":\"4c4122756b4bbdf867a17e5bac043da2\",
%% \"path\":\"/shapes/pump/a0_bd_1d_ce_8d_a7_1591271470.mp4\",
%% \"domain\":\"http://192.168.2.7:1250\",
%% \"scene\":\"pump\",
%% \"size\":16501663,
%% \"mtime\":1591271533,
%% \"scenes\":\"pump\",
%% \"retmsg\":\"\",
%% \"retcode\":0,
%% \"src\":\"/shapes/pump/a0_bd_1d_ce_8d_a7_1591271470.mp4\"}"

%%POST /shapes/upload HTTP/1.1
%%content-type: multipart/form-data; boundary=-----------------------acebdf135724681
%%content-length: 636
%%te:
%%host: 192.168.2.7:1250
%%connection: keep-alive
%%
%%-------------------------acebdf135724681
%%Content-Disposition: form-data;name="output"
%%
%%json
%%-------------------------acebdf135724681
%%Content-Disposition: form-data;name="scene"
%%
%%pump
%%-------------------------acebdf135724681
%%Content-Disposition: form-data;name="path"
%%
%%pump
%%-------------------------acebdf135724681
%%Content-Disposition: form-data;name="auth_token"
%%
%%r:a152e09b9bf9623712fd9c6f942fb20f
%%-------------------------acebdf135724681
%%Content-Disposition: form-data;name="text"; filename="a0_bd_1d_ce_8d_a7_1591269070.mp4"
%%Content-Type: application/octet-stream
%%
%%
%%-------------------------acebdf135724681--
%%
%%POST /shapes/upload HTTP/1.1
%%content-type: multipart/form-data; boundary=-----------------------acebdf135724681
%%content-length: 636
%%te:
%%host: 192.168.2.7:1250
%%connection: keep-alive
%%
%%-------------------------acebdf135724681
%%Content-Disposition: form-data;name="output"
%%
%%json
%%-------------------------acebdf135724681
%%Content-Disposition: form-data;name="scene"
%%
%%pump
%%-------------------------acebdf135724681
%%Content-Disposition: form-data;name="path"
%%
%%pump
%%-------------------------acebdf135724681
%%Content-Disposition: form-data;name="auth_token"
%%
%%r:a152e09b9bf9623712fd9c6f942fb20f
%%-------------------------acebdf135724681
%%Content-Disposition: form-data;name="text"; filename="a0_bd_1d_ce_8d_a7_1591269151.mp4"
%%Content-Type: application/octet-stream
%%
%%
%%-------------------------acebdf135724681--

-define(CRLF, "\r\n").
upload(Path, SessionToken) ->
    AppName = get_app(SessionToken),
    upload(Path, AppName, SessionToken).

upload(Path, AppName, SessionToken) ->
    inets:start(),
    Url = get_url(AppName),
    case file:read_file(Path) of
        {ok, Stream} ->
            FileName = dgiot_utils:to_binary(filename:basename(Path)),

            Boundary = <<"-----------------------acebdf135724681">>,
            Header = <<"--", Boundary/binary, ?CRLF, "Content-Disposition: form-data;name=\"">>,

            Data1 = <<"output\"", ?CRLF, ?CRLF, "json", ?CRLF>>,
            ParamBody1 = <<Header/binary, Data1/binary>>,

            Data2 = <<"scene\"", ?CRLF, ?CRLF, AppName/binary, ?CRLF>>,
            ParamBody2 = <<Header/binary, Data2/binary>>,

            Data3 = <<"path\"", ?CRLF, ?CRLF, AppName/binary, ?CRLF>>,
            ParamBody3 = <<Header/binary, Data3/binary>>,

            Data4 = <<"auth_token\"", ?CRLF, ?CRLF, SessionToken/binary, ?CRLF>>,
            ParamBody4 = <<Header/binary, Data4/binary>>,

            Data5 = <<"filename\"", ?CRLF, ?CRLF, FileName/binary, ?CRLF>>,
            ParamBody5 = <<Header/binary, Data5/binary>>,

            Tail = <<"--", Boundary/binary, "--", ?CRLF, ?CRLF>>,

            FileBody = <<Header/binary, "file\"; filename=\"", FileName/binary, "\"", ?CRLF,
                "Content-Type: application/octet-stream", ?CRLF, ?CRLF, Stream/binary, ?CRLF, Tail/binary>>,

            ParamBody = <<ParamBody1/binary, ParamBody2/binary, ParamBody3/binary, ParamBody4/binary, ParamBody5/binary>>,

            Body = <<ParamBody/binary, FileBody/binary>>,
            Size = byte_size(Body),
            ContentType = <<"multipart/form-data; boundary=", Boundary/binary>>,
            case httpc:request(post, {dgiot_utils:to_list(Url), [{"Content-Length", integer_to_list(Size)}], binary_to_list(ContentType), Body}, [], []) of
                {ok, {{"HTTP/1.1", 200, "OK"}, _, Json}} ->
                    case jsx:decode(dgiot_utils:to_binary(Json), [{labels, binary}, return_maps]) of
                        #{<<"md5">> := _Md5} = Data ->
                            {ok, Data};
                        Error1 -> Error1
                    end;
                Error -> Error
            end;
        {error, Reason} ->
            ?LOG(info, "Reason ~p ", [Reason]),
            {error, Reason}
    end.

get_url(AppName) ->
    Roleid = dgiot_parse:get_roleid(AppName),
    case dgiot_parse:get_object(<<"_Role">>, Roleid) of
        {ok, #{<<"tag">> := #{<<"appconfig">> := #{<<"file">> := Url}}}} ->
            Url;
        _ -> <<"">>
    end.

get_app(SessionToken) ->
    case dgiot_parse:query_object(<<"_Role">>, #{
        <<"keys">> => [<<"name">>],
        <<"limit">> => 1}, [{"X-Parse-Session-Token", SessionToken}], [{from, rest}]) of
        {ok, #{<<"results">> := Apps}} ->
            [#{<<"name">> := AppName} | _] = Apps,
            AppName;
        _ -> <<"">>
    end.

create_report(Config, DevType, Name, Num, Imagurl, WordUrl, SessionToken) ->
    ProductName = <<Name/binary, Num/binary>>,
    Id = dgiot_parse:get_productid(<<"Evidence">>, DevType, <<Name/binary, "0">>),
    ProductId = dgiot_parse:get_productid(<<"Evidence">>, DevType, <<Name/binary, Num/binary>>),
    NodeType =
        case Num of
            <<"0">> -> 1;
            _ -> 0
        end,
    NewConfig = maps:merge(#{<<"konva">> => #{
        <<"Stage">> => #{
            <<"attrs">> => #{
                <<"x">> => -525,
                <<"y">> => -35,
                <<"id">> => <<"stage_", ProductId/binary>>,
                <<"width">> => 1667,
                <<"height">> => 379,
                <<"draggable">> => true
            },
            <<"children">> => [
                #{
                    <<"attrs">> => #{
                        <<"id">> => <<"imagelayer_", ProductId/binary>>
                    },
                    <<"children">> => [
                        #{
                            <<"attrs">> => #{
                                <<"id">> => <<"group_", ProductId/binary>>,
                                <<"width">> => 2000,
                                <<"height">> => 2000
                            },
                            <<"children">> => [
                                #{
                                    <<"attrs">> => #{
                                        <<"id">> => <<"image_", ProductId/binary>>,
                                        <<"source">> => Imagurl
                                    },
                                    <<"className">> => <<"Image">>
                                }
                            ],
                            <<"className">> => <<"Group">>
                        }
                    ],
                    <<"className">> => <<"Layer">>
                }
            ],
            <<"className">> => <<"Stage">>
        }
    }}, Config),
    case dgiot_product:create_product(#{<<"config">> => NewConfig#{
        <<"id">> => Id,
        <<"reporttemp">> => dgiot_utils:to_binary(WordUrl)
    }, <<"thing">> => #{},
        <<"nodeType">> => NodeType,
        <<"devType">> => DevType,
        <<"desc">> => Num,
        <<"name">> => ProductName,
        <<"category">> => <<"Evidence">>}, SessionToken) of
        {ok, Result} ->
            #{ProductName => Result};
        {error, Error} ->
            #{ProductName => Error}
    end.

get_capture(#{<<"productid">> := ProductId, <<"topoid">> := TopoId, <<"thingid">> := ThingId} = Payload) ->
    case dgiot_parse:get_object(<<"Product">>, ProductId) of
        {ok, #{<<"config">> := Config, <<"thing">> := Thing}} ->
            ControlList =
                lists:foldl(fun(X, Acc) ->
                    case maps:with([<<"identifier">>, <<"style">>], X) of
                        #{<<"identifier">> := TopoId, <<"style">> := Style} ->
                            R0 = lists:foldl(fun(Y, Acc1) ->
                                case Y of
                                    #{<<"identifier">> := ThingId, <<"dataType">> := #{<<"specs">> := Specs}} ->
                                        Acc1 ++ [X#{
                                            <<"productId">> => ProductId,
                                            <<"deviceId">> => maps:get(<<"subdevid">>, Payload, <<"">>),
                                            <<"wumoxing">> => Specs#{
                                                <<"identifier">> => ThingId,
                                                <<"value">> => ""
                                            },
                                            <<"style">> => Style#{
                                                <<"backColor">> => <<"rgba(46,176,80,1)">>}}];
                                    _ -> Acc1
                                end
                                             end, [], maps:get(<<"properties">>, Thing)),
                            case R0 of
                                [] -> Acc ++ [X];
                                L0 -> Acc ++ L0
                            end;
                        _ -> Acc ++ [X]
                    end
                            end, [], maps:get(<<"components">>, Config)),
            Properties =
                lists:foldl(fun(X, Acc) ->
                    case maps:with([<<"identifier">>], X) of
                        #{<<"identifier">> := ThingId} ->
                            R = lists:foldl(fun(Y, Acc1) ->
                                case Y of
                                    #{<<"identifier">> := TopoId,
                                        <<"address">> := Address} ->
                                        ?LOG(info, "Address ~p", [Address]),
                                        Acc1 ++ [X#{<<"dataForm">> => #{
                                            <<"address">> => Address,
                                            <<"quantity">> => TopoId}}];
                                    _ ->
                                        Acc1
                                end
                                            end, [], maps:get(<<"components">>, Config)),
                            case R of
                                [] -> Acc ++ [X];
                                L -> Acc ++ L
                            end;
                        _ -> Acc ++ [X]
                    end
                            end, [], maps:get(<<"properties">>, Thing)),
            case dgiot_parse:update_object(<<"Product">>, ProductId, #{
                <<"config">> => Config#{<<"components">> => ControlList},
                <<"thing">> => Thing#{<<"properties">> => Properties}}) of
                {ok, _} -> {ok, #{
                    <<"config">> => Config#{<<"components">> => ControlList},
                    <<"thing">> => Thing#{<<"properties">> => Properties}}
                };
                Error -> Error
            end;
        Return ->
            Return
    end.

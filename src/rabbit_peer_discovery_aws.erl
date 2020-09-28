%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% The Initial Developer of the Original Code is AWeber Communications.
%% Copyright (c) 2015-2016 AWeber Communications
%% Copyright (c) 2016-2020 VMware, Inc. or its affiliates. All rights reserved.
%%

-module(rabbit_peer_discovery_aws).
-behaviour(rabbit_peer_discovery_backend).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbitmq_peer_discovery_common/include/rabbit_peer_discovery.hrl").

-export([init/0, list_nodes/0, supports_registration/0, register/0, unregister/0,
         post_registration/0, lock/1, unlock/1]).

-type tags() :: map().
-type filters() :: [{string(), string()}].

-ifdef(TEST).
-compile(export_all).
-endif.

% rabbitmq/rabbitmq-peer-discovery-aws#25

% Note: this timeout must not be greater than the default
% gen_server:call timeout of 5000ms. Note that `timeout`,
% when set, is used as the connect and then request timeout
% by `httpc`
-define(INSTANCE_ID_TIMEOUT, 2250).
-define(INSTANCE_ID_URL,
        "http://169.254.169.254/latest/meta-data/instance-id").

-define(CONFIG_MODULE, rabbit_peer_discovery_config).
-define(UTIL_MODULE,   rabbit_peer_discovery_util).

-define(BACKEND_CONFIG_KEY, peer_discovery_aws).

-define(CONFIG_MAPPING,
         #{
          aws_autoscaling                    => #peer_discovery_config_entry_meta{
                                                   type          = atom,
                                                   env_variable  = "AWS_AUTOSCALING",
                                                   default_value = false
                                                  },
          aws_ec2_tags                       => #peer_discovery_config_entry_meta{
                                                   type          = map,
                                                   env_variable  = "AWS_EC2_TAGS",
                                                   default_value = #{}
                                                  },
          aws_access_key                     => #peer_discovery_config_entry_meta{
                                                   type          = string,
                                                   env_variable  = "AWS_ACCESS_KEY_ID",
                                                   default_value = "undefined"
                                                  },
          aws_secret_key                     => #peer_discovery_config_entry_meta{
                                                   type          = string,
                                                   env_variable  = "AWS_SECRET_ACCESS_KEY",
                                                   default_value = "undefined"
                                                  },
          aws_ec2_region                     => #peer_discovery_config_entry_meta{
                                                   type          = string,
                                                   env_variable  = "AWS_EC2_REGION",
                                                   default_value = "undefined"
                                                  },
          aws_use_private_ip                 => #peer_discovery_config_entry_meta{
                                                   type          = atom,
                                                   env_variable  = "AWS_USE_PRIVATE_IP",
                                                   default_value = false
                                                  }
         }).

%%
%% API
%%

init() ->
    rabbit_log:debug("Peer discovery AWS: initialising..."),
    ok = application:ensure_started(inets),
    %% we cannot start this plugin yet since it depends on the rabbit app,
    %% which is in the process of being started by the time this function is called
    application:load(rabbitmq_peer_discovery_common),
    rabbit_peer_discovery_httpc:maybe_configure_proxy(),
    rabbit_peer_discovery_httpc:maybe_configure_inet6().

-spec list_nodes() -> {ok, {Nodes :: list(), NodeType :: rabbit_types:node_type()}} |
                      {error, Reason :: string()}.

list_nodes() ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    {ok, _} = application:ensure_all_started(rabbitmq_aws),
    rabbit_log:debug("Started rabbitmq_aws"),
    rabbit_log:debug("Will use AWS access key of '~s'", [get_config_key(aws_access_key, M)]),
    ok = maybe_set_region(get_config_key(aws_ec2_region, M)),
    ok = maybe_set_credentials(get_config_key(aws_access_key, M),
                               get_config_key(aws_secret_key, M)),
    case get_config_key(aws_autoscaling, M) of
        true ->
            get_autoscaling_group_node_list(instance_id(), get_tags());
        false ->
            get_node_list_from_tags(get_tags())
    end.

-spec supports_registration() -> boolean().

supports_registration() ->
    %% see rabbitmq-peer-discovery-aws#17
    true.


-spec register() -> ok.
register() ->
    ok.

-spec unregister() -> ok.
unregister() ->
    ok.

-spec post_registration() -> ok | {error, Reason :: string()}.

post_registration() ->
    ok.

-spec lock(Node :: atom()) -> not_supported.

lock(_Node) ->
    not_supported.

-spec unlock(Data :: term()) -> ok.

unlock(_Data) ->
    ok.

%%
%% Implementation
%%
-spec get_config_key(Key :: atom(), Map :: #{atom() => peer_discovery_config_value()})
                    -> peer_discovery_config_value().

get_config_key(Key, Map) ->
    ?CONFIG_MODULE:get(Key, ?CONFIG_MAPPING, Map).

-spec maybe_set_credentials(AccessKey :: string(),
                            SecretKey :: string()) -> ok.
%% @private
%% @doc Set the API credentials if they are set in configuration.
%% @end
%%
maybe_set_credentials("undefined", _) -> ok;
maybe_set_credentials(_, "undefined") -> ok;
maybe_set_credentials(AccessKey, SecretKey) ->
    rabbit_log:debug("Setting AWS credentials, access key: '~s'", [AccessKey]),
    rabbitmq_aws:set_credentials(AccessKey, SecretKey).


-spec maybe_set_region(Region :: string()) -> ok.
%% @private
%% @doc Set the region from the configuration value, if it was set.
%% @end
%%
maybe_set_region("undefined") -> ok;
maybe_set_region(Value) ->
    rabbit_log:debug("Setting AWS region to ~p", [Value]),
    rabbitmq_aws:set_region(Value).

get_autoscaling_group_node_list(error, _) ->
    rabbit_log:warning("Cannot discover any nodes: failed to fetch this node's EC2 "
                       "instance id from ~s", [?INSTANCE_ID_URL]),
    {ok, {[], disc}};
get_autoscaling_group_node_list(Instance, Tag) ->
    case get_all_autoscaling_instances([]) of
        {ok, Instances} ->
            case find_autoscaling_group(Instances, Instance) of
                {ok, Group} ->
                    rabbit_log:debug("Performing autoscaling group discovery, group: ~p", [Group]),
                    Values = get_autoscaling_instances(Instances, Group, []),
                    rabbit_log:debug("Performing autoscaling group discovery, found instances: ~p", [Values]),
                    case get_hostname_by_instance_ids(Values, Tag) of
                        error ->
                            Msg = "Cannot discover any nodes: DescribeInstances API call failed",
                            rabbit_log:error(Msg),
                            {error, Msg};
                        Names ->
                            rabbit_log:debug("Performing autoscaling group-based discovery, hostnames: ~p", [Names]),
                            {ok, {[?UTIL_MODULE:node_name(N) || N <- Names], disc}}
                    end;
                error ->
                    rabbit_log:warning("Cannot discover any nodes because no AWS "
                                       "autoscaling group could be found in "
                                       "the instance description. Make sure that this instance"
                                       " belongs to an autoscaling group.", []),
                    {ok, {[], disc}}
            end;
        _ ->
            Msg = "Cannot discover any nodes because AWS autoscaling group description API call failed",
            rabbit_log:warning(Msg),
            {error, Msg}
    end.

get_autoscaling_instances([], _, Accum) -> Accum;
get_autoscaling_instances([H|T], Group, Accum) ->
    GroupName = proplists:get_value("AutoScalingGroupName", H),
    case GroupName == Group of
        true ->
            Node = proplists:get_value("InstanceId", H),
            get_autoscaling_instances(T, Group, lists:append([Node], Accum));
        false ->
            get_autoscaling_instances(T, Group, Accum)
    end.

get_all_autoscaling_instances(Accum) ->
    QArgs = [{"Action", "DescribeAutoScalingInstances"}, {"Version", "2011-01-01"}],
    fetch_all_autoscaling_instances(QArgs, Accum).

get_all_autoscaling_instances(Accum, 'undefined') -> {ok, Accum};
get_all_autoscaling_instances(Accum, NextToken) ->
    QArgs = [{"Action", "DescribeAutoScalingInstances"}, {"Version", "2011-01-01"},
             {"NextToken", NextToken}],
    fetch_all_autoscaling_instances(QArgs, Accum).

fetch_all_autoscaling_instances(QArgs, Accum) ->
    Path = "/?" ++ rabbitmq_aws_urilib:build_query_string(QArgs),
    case api_get_request("autoscaling", Path) of
        {ok, Payload} ->
            Instances = flatten_autoscaling_datastructure(Payload),
            NextToken = get_next_token(Payload),
            get_all_autoscaling_instances(lists:append(Instances, Accum), NextToken);
        {error, Reason} = Error ->
            rabbit_log:error("Error fetching autoscaling group instance list: ~p", [Reason]),
            Error
    end.

flatten_autoscaling_datastructure(Value) ->
    Response = proplists:get_value("DescribeAutoScalingInstancesResponse", Value),
    Result = proplists:get_value("DescribeAutoScalingInstancesResult", Response),
    Instances = proplists:get_value("AutoScalingInstances", Result),
    [Instance || {_, Instance} <- Instances].

get_next_token(Value) ->
    Response = proplists:get_value("DescribeAutoScalingInstancesResponse", Value),
    Result = proplists:get_value("DescribeAutoScalingInstancesResult", Response),
    NextToken = proplists:get_value("NextToken", Result),
    NextToken.

api_get_request(Service, Path) ->
    case rabbitmq_aws:get(Service, Path) of
        {ok, {_Headers, Payload}} ->
            rabbit_log:debug("AWS request: ~s~nResponse: ~p~n",
                             [Path, Payload]),
            {ok, Payload};
        {error, {credentials, _}} -> {error, credentials};
        {error, Message, _} -> {error, Message}
    end.

-spec find_autoscaling_group(Instances :: list(), Instance :: string())
                            -> string() | error.
%% @private
%% @doc Attempt to find the Auto Scaling Group ID by finding the current
%%      instance in the list of instances returned by the autoscaling API
%%      endpoint.
%% @end
%%
find_autoscaling_group([], _) -> error;
find_autoscaling_group([H|T], Instance) ->
    case proplists:get_value("InstanceId", H) == Instance of
        true ->
            {ok, proplists:get_value("AutoScalingGroupName", H)};
        false ->
            find_autoscaling_group(T, Instance)
    end.

get_hostname_by_instance_ids(Instances, Tag) ->
    QArgs = build_instance_list_qargs(Instances,
                                      [{"Action", "DescribeInstances"},
                                       {"Version", "2015-10-01"}]),
    QArgs2 = lists:keysort(1, maybe_add_tag_filters(Tag, QArgs, 1)),
    Path = "/?" ++ rabbitmq_aws_urilib:build_query_string(QArgs2),
    get_hostname_names(Path).

-spec build_instance_list_qargs(Instances :: list(), Accum :: list()) -> list().
%% @private
%% @doc Build the Query args for filtering instances by InstanceID.
%% @end
%%
build_instance_list_qargs([], Accum) -> Accum;
build_instance_list_qargs([H|T], Accum) ->
    Key = "InstanceId." ++ integer_to_list(length(Accum) + 1),
    build_instance_list_qargs(T, lists:append([{Key, H}], Accum)).

-spec maybe_add_tag_filters(tags(), filters(), integer()) -> filters().
maybe_add_tag_filters(Tags, QArgs, Num) ->
    {Filters, _} =
        maps:fold(fun(Key, Value, {AccQ, AccN}) ->
                          {lists:append(
                             [{"Filter." ++ integer_to_list(AccN) ++ ".Name", "tag:" ++ Key},
                              {"Filter." ++ integer_to_list(AccN) ++ ".Value.1", Value}],
                             AccQ),
                           AccN + 1}
                  end, {QArgs, Num}, Tags),
    Filters.

-spec get_node_list_from_tags(tags()) -> {ok, {[node()], disc}}.
get_node_list_from_tags([]) ->
    rabbit_log:warning("Cannot discover any nodes because AWS tags are not configured!", []),
    {ok, {[], disc}};
get_node_list_from_tags(Tags) ->
    {ok, {[?UTIL_MODULE:node_name(N) || N <- get_hostname_by_tags(Tags)], disc}}.

get_hostname_name_from_reservation_set([], Accum) -> Accum;
get_hostname_name_from_reservation_set([{"item", RI}|T], Accum) ->
    InstancesSet = proplists:get_value("instancesSet", RI),
    Items = [Item || {"item", Item} <- InstancesSet],
    HostnameKey = select_hostname(),
    Hostnames = [Hostname || Item <- Items,
                             {HKey, Hostname} <- Item,
                             HKey == HostnameKey,
                             Hostname =/= ""],
    get_hostname_name_from_reservation_set(T, Accum ++ Hostnames).

get_hostname_names(Path) ->
    case api_get_request("ec2", Path) of
        {ok, Payload} ->
            Response = proplists:get_value("DescribeInstancesResponse", Payload),
            ReservationSet = proplists:get_value("reservationSet", Response),
            get_hostname_name_from_reservation_set(ReservationSet, []);
        {error, Reason} ->
            rabbit_log:error("Error fetching node list via EC2 API, request path: ~s, error: ~p", [Path, Reason]),
            error
    end.

get_hostname_by_tags(Tags) ->
    QArgs = [{"Action", "DescribeInstances"}, {"Version", "2015-10-01"}],
    QArgs2 = lists:keysort(1, maybe_add_tag_filters(Tags, QArgs, 1)),
    Path = "/?" ++ rabbitmq_aws_urilib:build_query_string(QArgs2),
    case get_hostname_names(Path) of
        error ->
            rabbit_log:warning("Cannot discover any nodes because AWS "
                               "instance description with tags ~p failed", [Tags]),
            [];
        Names ->
            Names
    end.

-spec select_hostname() -> string().
select_hostname() ->
    case get_config_key(aws_use_private_ip, ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY)) of
        true  -> "privateIpAddress";
        false -> "privateDnsName";
        _     -> "privateDnsName"
    end.

-spec instance_id() -> string() | error.
%% @private
%% @doc Return the local instance ID from the EC2 metadata service
%% @end
%%
instance_id() ->
    case httpc:request(get, {?INSTANCE_ID_URL, []},
                       [{timeout, ?INSTANCE_ID_TIMEOUT}], []) of
        {ok, {{_, 200, _}, _, Value}} ->
            rabbit_log:debug("Fetched EC2 instance ID from ~p: ~p",
                             [?INSTANCE_ID_URL, Value]),
            Value;
        Other ->
            rabbit_log:error("Failed to fetch EC2 instance ID from ~p: ~p",
                             [?INSTANCE_ID_URL, Other]),
            error
    end.

-spec get_tags() -> tags().
get_tags() ->
    Tags = get_config_key(aws_ec2_tags, ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY)),
    case Tags of
        Value when is_list(Value) ->
            maps:from_list(Value);
        _ -> Tags
    end.

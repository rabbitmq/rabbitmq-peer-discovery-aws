%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is AWeber Communications.
%% Copyright (c) 2015-2016 AWeber Communications
%% Copyright (c) 2016-2017 Pivotal Software, Inc. All rights reserved.
%%

-module(rabbit_peer_discovery_aws).
-behaviour(rabbit_peer_discovery_backend).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbitmq_peer_discovery_common/include/rabbit_peer_discovery.hrl").

-export([list_nodes/0, supports_registration/0, register/0, unregister/0,
         post_registration/0]).

-type tags() :: [{string(), string()}].
-type filters() :: [{string(), string()}].

-ifdef(TEST).
-compile(export_all).
-endif.

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
                                                   type          = proplist,
                                                   env_variable  = "AWS_EC2_TAGS",
                                                   default_value = []
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
                                                   env_variable  = "AWS_DEFAULT_REGION",
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

-spec list_nodes() -> {ok, {Nodes :: list(), NodeType :: rabbit_types:node_type()}}.

list_nodes() ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    {ok, _} = application:ensure_all_started(rabbitmq_aws),
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
    false.


-spec register() -> ok.
register() ->
    ok.

-spec unregister() -> ok.
unregister() ->
    ok.

-spec post_registration() -> ok | {error, Reason :: string()}.

post_registration() ->
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
                            rabbit_log:error("Cannot discover any nodes: DescribeInstances "
                                             "API call failed.", []),
                            {ok, {[], disc}};
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
            rabbit_log:warning("Cannot discover any nodes because AWS "
                               "autoscaling group description API call failed.", []),
            {ok, {[], disc}}
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
maybe_add_tag_filters([], QArgs, _) -> QArgs;
maybe_add_tag_filters([{Key, Value}|T], QArgs, Num) ->
    maybe_add_tag_filters(
      T,
      lists:append(
        [{"Filter." ++ integer_to_list(Num) ++ ".Name", "tag:" ++ Key},
         {"Filter." ++ integer_to_list(Num) ++ ".Value.1", Value}],
        QArgs),
      Num+1).

-spec get_node_list_from_tags(tags()) -> {ok, {[node()], disc}}.
get_node_list_from_tags([]) ->
    rabbit_log:warning("Cannot discover any nodes because AWS tags are not configured!", []),
    {ok, {[], disc}};
get_node_list_from_tags(Tags) ->
    {ok, {[?UTIL_MODULE:node_name(N) || N <- get_hostname_by_tags(Tags)], disc}}.

get_hostname_name_from_reservation_set([], Accum) -> Accum;
get_hostname_name_from_reservation_set([{"item", RI}|T], Accum) ->
    InstancesSet = proplists:get_value("instancesSet", RI),
    Item = proplists:get_value("item", InstancesSet),
    DNSName = proplists:get_value(select_hostname(), Item),
    if
        DNSName == [] -> get_hostname_name_from_reservation_set(T, Accum);
        true -> get_hostname_name_from_reservation_set(T, lists:append([DNSName], Accum))
    end.

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
    case httpc:request(?INSTANCE_ID_URL) of
        {ok, {{_, 200, _}, _, Value}} -> Value;
        _ -> error
    end.

-spec get_tags() -> tags().
get_tags() ->
    Tags = get_config_key(aws_ec2_tags, ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY)),
    if
        Tags == "unused" -> [{"ignore", "me"}]; %% this is to trick dialyzer
        true -> Tags
    end.

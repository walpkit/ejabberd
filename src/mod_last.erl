%%%----------------------------------------------------------------------
%%% File    : mod_last.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : jabber:iq:last support (XEP-0012)
%%% Created : 24 Oct 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2010   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

%%% Database schema (version / storage / table)
%%%
%%% 2.1.x / mnesia / last_activity
%%%  us = {Username::string(), Host::string()}
%%%  timestamp = now()
%%%  status = string()
%%%
%%% 2.1.x / odbc / last
%%%  username = varchar250
%%%  seconds = text
%%%  state = text
%%%
%%% 3.0.0-prealpha / mnesia / last_activity
%%%  us = {Username::binary(), Host::binary()}
%%%  timestamp = now()
%%%  status = binary()
%%%
%%% 3.0.0-prealpha / odbc / last
%%%  Same as 2.1.x
%%%
%%% 3.0.0-alpha / mnesia / last_activity
%%%  user_host = {Username::binary(), Host::binary()}
%%%  timestamp = now()
%%%  status = binary()
%%%
%%% 3.0.0-alpha / odbc / last_activity
%%%  user = varchar150
%%%  host = varchar150
%%%  timestamp = bigint
%%%  status = text

-module(mod_last).
-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2,
	 stop/1,
	 process_local_iq/3,
	 process_sm_iq/3,
	 on_presence_update/4,
	 store_last_info/4,
	 get_last_info/2,
	 remove_user/2]).

-include_lib("exmpp/include/exmpp.hrl").

-include("ejabberd.hrl").
-include("mod_privacy.hrl").

-record(last_activity, {user_host, timestamp, status}).


start(Host, Opts) ->
    HostB = list_to_binary(Host),
    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
    Backend = gen_mod:get_opt(backend, Opts, mnesia),
    gen_storage:create_table(Backend, HostB, last_activity,
			     [{disc_copies, [node()]},
			      {odbc_host, Host},
			      {attributes, record_info(fields, last_activity)},
			      {types, [{user_host, {text, text}},
				       {timestamp, bigint}]}]),
    update_table(Host, Backend),
    gen_iq_handler:add_iq_handler(ejabberd_local, HostB, ?NS_LAST_ACTIVITY,
				  ?MODULE, process_local_iq, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, HostB, ?NS_LAST_ACTIVITY,
				  ?MODULE, process_sm_iq, IQDisc),
    ejabberd_hooks:add(remove_user, HostB,
		       ?MODULE, remove_user, 50),
    ejabberd_hooks:add(unset_presence_hook, HostB,
		       ?MODULE, on_presence_update, 50).

stop(Host) ->
    HostB = list_to_binary(Host),
    ejabberd_hooks:delete(remove_user, HostB,
			  ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(unset_presence_hook, HostB,
			  ?MODULE, on_presence_update, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, HostB, ?NS_LAST_ACTIVITY),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, HostB, ?NS_LAST_ACTIVITY).

%%%
%%% Uptime of ejabberd node
%%%

process_local_iq(_From, _To, #iq{type = get} = IQ_Rec) ->
    Sec = get_node_uptime(),
    Response = #xmlel{ns = ?NS_LAST_ACTIVITY, name = 'query', attrs =
      [?XMLATTR('seconds', Sec)]},
    exmpp_iq:result(IQ_Rec, Response);
process_local_iq(_From, _To, #iq{type = set} = IQ_Rec) ->
    exmpp_iq:error(IQ_Rec, 'not-allowed').

%% @spec () -> integer()
%% @doc Get the uptime of the ejabberd node, expressed in seconds.
%% When ejabberd is starting, ejabberd_config:start/0 stores the datetime.
get_node_uptime() ->
    case ejabberd_config:get_local_option(node_start) of
 {_, _, _} = StartNow ->
     now_to_seconds(now()) - now_to_seconds(StartNow);
 _undefined ->
     trunc(element(1, erlang:statistics(wall_clock))/1000)
    end.

now_to_seconds({MegaSecs, Secs, _MicroSecs}) ->
    MegaSecs * 1000000 + Secs.


%%%
%%% Serve queries about user last online
%%%

process_sm_iq(From, To, #iq{type = get} = IQ_Rec) ->
    {Subscription, _Groups} =
	ejabberd_hooks:run_fold(
	  roster_get_jid_info, exmpp_jid:prep_domain(To),
	  {none, []}, [exmpp_jid:prep_node(To), exmpp_jid:prep_domain(To), From]),
    if
	(Subscription == both) or (Subscription == from) ->
	    UserListRecord = ejabberd_hooks:run_fold(
			       privacy_get_user_list, exmpp_jid:prep_domain(To),
			       #userlist{},
			       [exmpp_jid:prep_node(To), exmpp_jid:prep_domain(To)]),
	    case ejabberd_hooks:run_fold(
		   privacy_check_packet, exmpp_jid:prep_domain(To),
		   allow,
		   [exmpp_jid:prep_node(To), exmpp_jid:prep_domain(To), UserListRecord,
		    {To, From,
		     exmpp_presence:available()},
		    out]) of
		allow ->
		    get_last(IQ_Rec, exmpp_jid:prep_node(To), exmpp_jid:prep_domain(To));
		deny ->
		    exmpp_iq:error(IQ_Rec, 'forbidden')
	    end;
	true ->
	    exmpp_iq:error(IQ_Rec, 'forbidden')
    end;
process_sm_iq(_From, _To, #iq{type = set} = IQ_Rec) ->
    exmpp_iq:error(IQ_Rec, 'not-allowed').

%% TODO: This function could use get_last_info/2
get_last(IQ_Rec, LUser, LServer) ->
    case catch gen_storage:dirty_read(LServer, last_activity, {LUser, LServer}) of
	{'EXIT', _Reason} ->
	    exmpp_iq:error(IQ_Rec, 'internal-server-error');
	[] ->
	    exmpp_iq:error(IQ_Rec, 'service-unavailable');
	[#last_activity{timestamp = TimeStamp, status = Status}] ->
	    {MegaSecs, Secs, _MicroSecs} = now(),
	    TimeStamp2 = MegaSecs * 1000000 + Secs,
	    Sec = TimeStamp2 - TimeStamp,
	    Response = #xmlel{ns = ?NS_LAST_ACTIVITY, name = 'query',
	      attrs = [?XMLATTR('seconds', Sec)],
	      children = [#xmlcdata{cdata = Status}]},
	    exmpp_iq:result(IQ_Rec, Response)
    end.



on_presence_update(User, Server, _Resource, Status) ->
    {MegaSecs, Secs, _MicroSecs} = now(),
    TimeStamp = MegaSecs * 1000000 + Secs,
    store_last_info(User, Server, TimeStamp, Status).

store_last_info(User, Server, TimeStamp, Status) 
        when is_binary(User), is_binary(Server) ->
    try
	US = {User, Server},
	F = fun() ->
 		gen_storage:write(Server,
 				  #last_activity{user_host = US,
						timestamp = TimeStamp,
						status = Status})
	    end,
        gen_storage:transaction(Server, last_activity, F)
    catch
	_ ->
	    ok
    end.

%% @spec (LUser::string(), LServer::string()) ->
%%      {ok, Timestamp::integer(), Status::string()} | not_found
get_last_info(LUser, LServer) when is_list(LUser), is_list(LServer) ->
    get_last_info(list_to_binary(LUser), list_to_binary(LServer));
get_last_info(LUser, LServer) when is_binary(LUser), is_binary(LServer) ->
    case catch gen_storage:dirty_read(LServer, last_activity, {LUser, LServer}) of
	{'EXIT', _Reason} ->
	    not_found;
	[] ->
	    not_found;
	[#last_activity{timestamp = TimeStamp, status = Status}] ->
	    {ok, TimeStamp, Status}
    end.

remove_user(User, Server) when is_binary(User), is_binary(Server) ->
    try
	LUser = exmpp_stringprep:nodeprep(User),
	LServer = exmpp_stringprep:nameprep(Server),
	US = {LUser, LServer},
	F = fun() ->
		gen_storage:delete(LServer, {last_activity, US})
	    end,
	gen_storage:transaction(LServer, last_activity, F)
    catch
	_ ->
	    ok
    end.

update_table(Host, mnesia) ->
    gen_storage_migration:migrate_mnesia(
      Host, last_activity,
      [{last_activity, [us, timestamp, status],
	fun({last_activity, {U, S}, Timestamp, Status}) ->
		U1 = case U of
			 "" -> undefined;
			 V  -> V
		     end,
		#last_activity{user_host = {list_to_binary(U1),
					    list_to_binary(S)},
			       timestamp = Timestamp,
			       status = list_to_binary(Status)}
	end}]);
update_table(Host, odbc) ->
    gen_storage_migration:migrate_odbc(
      Host, [last_activity],
      [{"last", ["username", "seconds", "state"],
	fun(_, Username, STimeStamp, Status) ->
		case catch list_to_integer(STimeStamp) of
		    TimeStamp when is_integer(TimeStamp) ->
			[#last_activity{user_host = {Username, Host},
					timestamp = TimeStamp,
					status = Status}];
		    _ ->
			?WARNING_MSG("Omitting last_activity migration item"
				     " with timestamp=~p",
				     [STimeStamp])
		end
	end}]).

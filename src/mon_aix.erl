-module(mon_aix).

-include("metric.hrl").

-include_lib("elog/include/elog.hrl").

-export([run/1]).

run(Args) ->
	Ts = extbif:timestamp(),
    {unix, OsType} = os:type(),
    {value, Dn} = dataset:get_value(dn, Args),
    Output = os:cmd("uptime"),
    {CpuInfo, CpuDatalog} = load(Dn, Ts, Output),
    TaskOutput = os:cmd("ps -ef | wc -l"),
    TaskMetric = task(Dn, Ts, TaskOutput),
    MemOutput = os:cmd("svmon -G"),
    {MemInfo, MemData} = memory(MemOutput),
    SwapOutput = os:cmd("swap -l"),
    {SwapInfo, SwapData} = swap(SwapOutput),
    MemSwapMetric = #metric{name='host.mem', 
							 from="agent",
							 dn=Dn,
							 timestamp=Ts, 
							 data=MemData ++ SwapData},
    DiskOutput = os:cmd("df -k"),
    {DiskInfo, DiskDatalogs} = disk(Dn, Ts, DiskOutput),
    %%host info
    HostInfo = [{os_type, atom_to_list(OsType)},
                {ip_addrs, inet_info()}, 
                {cpu_info, CpuInfo}, 
                {mem_info, MemInfo}, 
                {swap_info, SwapInfo}, 
                {disk_info, DiskInfo}],
    %metrics
    Datalogs = [CpuDatalog, MemSwapMetric, TaskMetric | DiskDatalogs],
    {ok, HostInfo, Datalogs}.

load(Dn, Ts, Output) ->
    {Load1, Load5, Load15} = 
    case re:run(Output, "load averages:\\s+(\\d+.\\d+),\\s+(\\d+.\\d+),\\s+(\\d+.\\d+)", [{capture, [1,2,3], list}]) of
    {match, [SLoad1, SLoad5, SLoad15]} ->
        {SLoad1, SLoad5, SLoad15};
    nomatch ->
        ?WARNING("cpu nomatch", []),
        {"0.0", "0.0", "0.0"}
    end,
    CpuInfo = lists:concat(["load1=", Load1, ", load5=", Load5, ", load15=", Load15]),
	Data = [{cpu1min, list_to_float(Load1)}, 
			{cpu5min, list_to_float(Load5)}, 
			{cpu15min, list_to_float(Load15)}],
    CpuMetric = #metric{name='host.load',
						from="agent",
						dn=Dn,
						timestamp=Ts, 
						data=Data}, 
    {CpuInfo, CpuMetric}.

task(Dn, Ts, Output) ->
    TaskTotal = list_to_integer(string:strip(Output, both, $\n)),
	#metric{name='host.task', 
			from="agent",
			dn=Dn,
			timestamp=Ts,
			data=[{taskTotal, TaskTotal}]}.

memory(Output) ->
    [_, MemLine|_] = string:tokens(Output, "\n"),
    {MemTotal, MemUsed, MemFree} = 
    case re:run(MemLine, "memory\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+", 
        [{capture, [1,2,3], list}]) of
    {match, [Total,Used,Free]} ->
        list_to_tuple([list_to_integer(L) * 4096 || L <- [Total, Used, Free]]);
    nomatch ->
        ?WARNING("mem nomatch: ~p", [MemLine]),
        {0,0,0}
    end,
    MemUsage = 
    case MemTotal == 0 of
    true -> 0;
    false -> (MemUsed * 100) div MemTotal
    end,
    MemInfo = lists:concat(["total=", MemTotal, ", used=", MemUsed, 
        ", free=", MemFree, ", usage=", MemUsage, "%"]),
    MemData = [{memTotal, MemTotal}, {memUsed, MemUsed}, 
        {memFree, MemFree}, {memUsage, MemUsage}],
    {MemInfo, MemData}.

swap(SwapOutput) ->
    {SwapTotal, SwapFree} = 
    case re:run(SwapOutput, "\\s+(\\d+)MB\\s+(\\d+)MB", [{capture, [1,2], list}]) of
    {match, [Total,Free]} ->
        list_to_tuple([list_to_integer(L) * 1024 * 1024 || L <- [Total, Free]]);
    nomatch ->
        {0,0}
    end,
    SwapUsed = SwapTotal - SwapFree,
    SwapUsage = 
    case SwapTotal == 0 of
    true -> 0;
    false -> (SwapUsed * 100) div SwapTotal
    end,
    SwapInfo = lists:concat(["total=", SwapTotal, ", used=", SwapUsed, 
        ", free=", SwapFree, ", usage=", SwapUsage, "%"]),
    SwapData = [{swapTotal, SwapTotal}, {swapUsed, SwapUsed}, 
        {swapFree, SwapFree}, {swapUsage, SwapUsage}],
    {SwapInfo, SwapData}.

disk(Dn, Ts, Output) ->
    [_|Lines] = string:tokens(Output, "\r\n"),
    parse(Dn, Ts, Lines).

parse(Dn, Ts, Lines) ->
    parse(Dn, Ts, Lines, []).

parse(_Dn, _Ts, [], InfoAcc) ->
    {string:join(lists:reverse(InfoAcc), "\n"), []};

parse(Dn, Ts, ["/proc" ++ _|Lines], InfoAcc) ->
    parse(Dn, Ts, Lines, InfoAcc);

parse(Dn, Ts, [Line|Lines], InfoAcc) ->
    Tokens = string:tokens(Line, " "),
    Dev = lists:nth(1, Tokens),
    Total = list_to_integer(lists:nth(2, Tokens)),
    Free = list_to_integer(lists:nth(4, Tokens)),
    Used = Total - Free,
    Usage = (Used * 100) div Total,
    Info = lists:concat(["dev=", Dev, ", total=", Total, 
        "(KB), avail=", Free, "(KB), used=", Used, 
        "(KB), usage=", Usage, "%"]),
    %DiskDn = lists:concat(["disk=", Dev, ",", Dn]),
    %Datalog = {metric, <<"host.disk">>, DiskDn, Ts, [
    %        {diskTotal, Total}, {diskUsed, Used}, 
    %        {diskFree, Free}, {diskUsage, Usage}]},
    parse(Dn, Ts, Lines, [Info|InfoAcc]).

inet_info() ->
    {ok, IfNames} = inet:getiflist(),
    IfList = [ begin {ok, [{addr, Addr}|_]} = inet:ifget(IfName, [addr]), {IfName, inet_parse:ntoa(Addr)} end || IfName <- IfNames],
    IfList1 = [E || {_Name, Addr} = E <- IfList, Addr =/= "127.0.0.1"],
    string:join([Name ++ ": " ++ Addr || {Name, Addr} <- IfList1], ",").


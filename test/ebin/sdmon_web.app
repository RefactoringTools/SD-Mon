
{application, sdmon_web, [
	{description, "SD-Mon visualization via Cowboy webserver and websocket communication"},
	{vsn, "1"},
	{modules, []},
	{registered, []},
	{applications, [
		kernel,
		stdlib,
		cowboy
	]},
	{mod, {sdmon_web_app, []}},
	{env, []}
]}.

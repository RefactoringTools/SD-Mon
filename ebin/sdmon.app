{application,sdmon,
             [{description,"SD Erlang Monitoring."},
              {vsn,"1.0"},
              {modules,[sdmon,sdmon_sup, sdmon_master,sdmon_app,sdmon_worker,sdmon_trace]},
              {registered,[]},
              {applications,[kernel,stdlib]},
              {mod,{sdmon_app,[]}},
              {env,[]}]}.

SD-MON -- SD Erlang Monitor
---------------------------

Revision history
----------------
Rev. A - 04/02/2015
- First release for D5.4 delivery.

Rev. B01 - 10/02/2015
- Added Makefile and localhost IP configuration.

Introduction 
------------
SD-Mon is a tool aimed to monitor SD-Erlang systems.

This purpose is accomplished by means a "shadow" network
of agents, mapped on the running system.  
The network is deployed on the base of a configuration file describing 
the network architecture in terms of hosts, Erlang nodes, global group 
and s\_group partitions. Tracing to be performed on monitored nodes is
also specified within the configuration file. 

An agent is started by a master SD-Mon node for each s\_group and for
each free node. Configured tracing is applied on every monitored node, 
and traces are stored in binary format in the agent file system. 

The shadow network follows system changes so that agents are started
and stopped at runtime according to the needs. Such changes are 
persistently stored so that the last configuration can be reproduced
after a restart. Of course the shadow network can be always updated
via the User Interface.

As soon as an agent is stopped the related tracing files are fetched 
across the network by the master and they are made available in a
readable format in the master file system and statistics are generated.

Description
-----------
A detailed description can be found in document
"SD-Mon Tool Description".

Installation
------------
```bash
git clone https://github.com/RefactoringTools/SD-Mon
cd SD-Mon
make
```

How to run SD-Mon
-----------------
SD-Mon is started by executing from the base directory ($HOME/SD-Mon) the
bash script:

```bash
bin/sdmon_start
```

configuration files are read and the shadow network is started.
By executing:

```bash
bin/sdmon_stop
```

SD-Mon is stopped: all tracing is removed, agents are terminated and
all tracing files are downloaded in the master fylesystem (traces dir).

### Example 1: SD-ORBIT on single-host

Open a terminal and type:

```bash
export PATH=$HOME/SD-Mon/bin/:$HOME/SD-Mon/test/bin/:$PATH
cd $HOME/SD-Mon
cd test/config
rm test.config  # if it exists
ln -s test.config.orbit test.config
cd ../../
run_env
sdmon_start -v
```

open a new terminal and attach to node1 erlang shell:

```bash
export PATH=$HOME/SD-Mon/bin/:$HOME/SD-Mon/test/bin/:$PATH
cd $HOME/SD-Mon
to_nodes node1
sdmon_test:run_orbit_on_five_nodes().
```

back on the first terminal:

```erlang
application:stop(sdmon).
```

find tracing and statistics in $HOME/SD-Mon/traces.

### Example 2: SD-ORBIT on multi-host

Some prerequisites apply in the multi-host case:

* SD-Mon must be installed in the home directory of the local host and on all
  non-local hosts.
* User must be able to execute SSH commands on target non-local hosts without
  the needs to provide a password (use ssh-keygen if needed). This demo runs on
  myrtle.kent.ac.uk (129.12.3.176) and on dove.kent.ac.uk (129.12.3.211). The
  userid granted to access remote nodes via SSH without password must be defined
  in test.config file (‘uid’ tag).

Edit the file `$HOME/SD-Mon/test/config/test.config.orbit_3h` 
and replace the string "md504" with the proper userid (see above).

Now open a terminal and type:

```bash
export PATH=$HOME/SD-Mon/bin/:$HOME/SD-Mon/test/bin/:$PATH
cd $HOME/SD-Mon
cd test/config
rm test.config
ln -s test.config.orbit_3h test.config
cd ../../
run_env
sdmon_start -v
```

open a new terminal and attach to node1 erlang shell:

```bash
export PATH=$HOME/SD-Mon/bin/:$HOME/SD-Mon/test/bin/:$PATH
cd $HOME/SD-Mon
to_nodes node1
sdmon_test:run_orbit_on_nine_nodes().
```

back on the first terminal:

<<<<<<< HEAD
> application:stop(sdmon).

find tracing and statistics in $HOME/SD-Mon/traces.



=======
```bash
application:stop(sdmon).
```
>>>>>>> 7c5b860f1d314db3003264f1bc552ef87ca5c738

find tracing and statistics in `$HOME/SD-Mon/traces`.

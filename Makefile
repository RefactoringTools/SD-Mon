

all: clean inst
	@erlc -o ebin src/*.erl
	@erlc -o test/ebin test/src/sdmon_test.erl


clean:
	@rm -f ebin/*.beam 
	@rm -f test/ebin/sdmon_test.beam 
	@rm -f erl_crash.dump 
	
	
inst:
	@if ! grep -q -s "SD-Mon" ~/.erlang; \
	then echo "code:add_pathsa([\""$(PWD)/ebin\",\"$(PWD)/test/ebin\"]\). >> ~/.erlang; \
	fi




web: deps
	@rebar compile
	@erlc -o test/ebin test/src/*.erl
	@ln -sf test/priv

deps:
	@rebar get-deps

webclean:
	@rebar clean


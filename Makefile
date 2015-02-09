

all: clean
	@erlc -o ebin src/*.erl >/dev/null



clean:
	@rm -f ebin/*.beam shell
	@rm -f erl_crash.dump >/dev/null
	
	



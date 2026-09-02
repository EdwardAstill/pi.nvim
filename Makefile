.PHONY: test smoke

test:
	nvim --headless --clean -u tests/minimal_init.lua -c "lua dofile('tests/run.lua')"

smoke:
	nvim --headless --clean -u tests/minimal_init.lua -c "lua dofile('tests/smoke.lua')"

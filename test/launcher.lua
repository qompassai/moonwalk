-- Launches the debugger against the local test server (127.0.0.1:4278).
loadfile('publish/script/debugger.lua')('publish'):start('127.0.0.1:4278'):event('wait')

print('ok')

-- loop.lua: minimal long-running debuggee for launch/session cases.
--
-- Prints a bounded number of ticks and exits on its own. Bounded (not
-- infinite) so a case that forgets to disconnect still terminates; long
-- enough that kill-the-debuggee cases have a live target.
for i = 1, 500 do
    print('tick ' .. i)
end
print('loop done')

-- moonwalk/user.lua
--
-- Loads the user's optional moonwalk init file once per worker. The file
-- is trusted user code (like an init.lua): it typically requires
-- `moonwalk.formatters` / `moonwalk.hooks` and registers customizations.
--
-- Lookup order: `$MOONWALK_INIT`, then `$HOME/.config/moonwalk/init.lua`.
-- Absence is fine; load errors are logged, never fatal.

local log = require('common.log')

local m = {}

local loaded = false

function m.load_once()
    if loaded then
        return
    end
    loaded = true
    local path = os.getenv('MOONWALK_INIT')
    if not path or path == '' then
        local home = os.getenv('HOME')
        if not home or home == '' then
            return
        end
        path = home .. '/.config/moonwalk/init.lua'
    end
    local chunk, err = loadfile(path)
    if not chunk then
        -- Missing file is the common case; only log real load errors when
        -- the file exists but does not compile.
        local f = io.open(path, 'r')
        if f then
            f:close()
            log.error('moonwalk: cannot load ' .. path .. ': ' .. tostring(err))
        end
        return
    end
    local ok, runerr = pcall(chunk)
    if not ok then
        log.error('moonwalk: error in ' .. path .. ': ' .. tostring(runerr))
    end
end

return m

#!/usr/bin/env lua5.4
local lm = require('luamake')

lm.builddir = ('build/%s/%s'):format(lm.platform, lm.mode)
lm:import('compile/common/bee.lua')
require('compile.common.moonwalk')

lm.runtime_platform = lm.platform
require('compile.linux.runtime')

lm:default({
    'common',
    'moonwalk',
    'runtime',
    'launcher',
})

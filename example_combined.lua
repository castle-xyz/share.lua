-- This runs both the client and server in the same process for easy testing

USE_CASTLE_CONFIG = true
require 'example_server'
require 'example_client'


-- Below code is some stuff I use to find performance issues

--local profile = require 'https://bitbucket.org/itraykov/profile.lua/raw/87ed5148b5def03002b38f80350794c2ddf7ba1d/profile.lua'
--
--profile.hookall('Lua')
--profile.start()
--
--local timeTillNextReport = 0
--local oldUpdate = love.update
--function love.update(dt)
--    oldUpdate(dt)
--
--    timeTillNextReport = timeTillNextReport - dt
--    if timeTillNextReport <= 0 then
--        print(profile.report())
--        profile.reset()
--        timeTillNextReport = 2
--    end
--end

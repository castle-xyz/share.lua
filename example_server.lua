local cs = require 'cs'
local server = cs.server


server.enabled = true
server.start('22122') -- Port of server


-- Server has many clients connecting to it. Each client has a unique `id` to identify it.
--
-- `server.share` represents shared state that the server can write to and all clients can read
-- from. `server.homes[id]` each represents state that the server can read from and client with
-- that `id` can write to (clients can't see each other's homes). Thus the server gets data
-- from each client and combines them for all clients to see.
--
-- Server can also send or receive individual messages to or from any client.


local share = server.share -- Maps to `client.share` -- can write
local homes = server.homes -- `homes[id]` maps to `client.home` for that `id` -- can read


function server.connect(id) -- Called on connect from client with `id`
    share.mice[id] = {
        x = 0, y = 0,
        r = math.random(),
        g = math.random(),
        b = math.random(),
    }
end

function server.disconnect(id) -- Called on disconnect from client with `id`
end

function server.receive(id, ...) -- Called when client with `id` does `client.send(...)`
end


-- Server only gets `.load`, `.update`, `.quit` Love events (also `.lowmemory` and `.threaderror`
-- which are less commonly used)

function server.load()
    share.mice = {}
    local w, h = love.graphics.getDimensions()
    for i = 200, 4000 do
        share.mice[i] = {
            x = w * math.random(), y = h * math.random(),
            r = math.random(),
            g = math.random(),
            b = math.random(),
            oscSpeed = math.random(),
        }
    end
    share.mice:__relevance(function(self, id)
        local keys = {}
        for i = 200, 600 do
            keys[i] = true
        end
        return keys
    end)
end

function server.update(dt)
    for id, home in pairs(server.homes) do -- Combine mouse info from clients into share
        if home.mouse then
            local mouse = share.mice[id]
            mouse.x, mouse.y = home.mouse.x, home.mouse.y
        end
    end
    for id, mouse in pairs(share.mice) do
        if mouse.oscSpeed then
            mouse.x = mouse.x + 10 * mouse.oscSpeed * math.sin(love.timer.getTime())
        end
    end
end

function love.draw()
    love.graphics.print('fps: ' .. love.timer.getFPS(), 20, 20)
end

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
--        timeTillNextReport = 10
--    end
--end

local cs = require 'cs'
local server = cs.server

if USE_CASTLE_CONFIG then
    server.useCastleConfig()
else
    server.enabled = true
    server.start('22122') -- Port of server
end


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
    print('client ' .. id .. ' connected')
end

function server.disconnect(id) -- Called on disconnect from client with `id`
    print('client ' .. id .. ' disconnected')
    share.mice[id] = nil
end

function server.receive(id, ...) -- Called when client with `id` does `client.send(...)`
end


-- Server only gets `.load`, `.update`, `.quit` Love events (also `.lowmemory` and `.threaderror`
-- which are less commonly used)

function server.load()
    share.mice = {}
end

function server.update(dt)
    for id, home in pairs(server.homes) do -- Combine mouse info from clients into share
        share.mice[id] = home.mouse
    end
end

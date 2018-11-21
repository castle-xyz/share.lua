local cs = require 'cs'
local server = cs.server


server.enabled = true
server.start('22122') -- Port of server


-- Server has many clients connecting to it. Each client has a unique `id` to identify it.
--
-- `server.share` represents shared state that the server can write to and all clients can read
-- from. `server.boxes[id]` each represents state that the server can read from and client with
-- that `id` can write to (clients can't see each other's boxes). Thus the server gets data
-- from each client and combines them for all clients to see.
--
-- Server can also receive individual messages from `client.send(...)` on client.


local share = server.share -- Maps to `client.share` -- can write
local boxes = server.boxes -- `boxes[id]` maps to `client.box` for that `id` -- can read

function server.connect(id) -- Called on connect from client with `id`
end

function server.disconnect(id) -- Called on disconnect from client with `id`
end

function server.receive(id, ...) -- Called on `client.send(...)` from client with `id`
end


-- Server only gets `.load` and `.update` Love events

function server.load()
end

function server.update(dt)
end

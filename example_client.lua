local cs = require 'cs'
local client = cs.client


client.enabled = true
client.start('127.0.0.1:22122') -- IP address ('127.0.0.1' is same computer) and port of server


-- Client connects to server. It gets a unique `id` to identify it.
--
-- `client.share` represents the shared state that server can write to and any client can read from.
-- `client.box` represents the box for this client that only it can write to and only server can
-- read from. `client.id` is the `id` for this client (set once it connects).
--
-- Client can also send individual messages using `client.send(...)` to server.


local share = client.share -- Maps to `server.share` -- can read
local box = client.box -- Maps to `server.boxes[client.id]` -- can write

function client.connect() -- Called on connect from server
end

function client.disconnect() -- Called on disconnect from server
end

function client.update(dt)
end

function client.draw()
end


-- Client gets all Love events

function client.load()
end


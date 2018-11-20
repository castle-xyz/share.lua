local share = require 'share'


local enet = require 'enet' -- Network
local marshal = require 'marshal' -- Serialization
local serpent = require 'https://raw.githubusercontent.com/pkulchenko/serpent/522a6239f25997b101c585c0daf6a15b7e37fad9/src/serpent.lua' -- Table printing


-- Super basic example where you can press keys to show the key name on the screen, and click with
-- the mouse to change where it's displayed.
--
-- Press 1 to start the server, and 2 to connect the client.

-- You could write server and client code each in separate files and that probably helps make it
-- clear what's visible to what. But to keep the repo clean and allow testing server-client
-- connection withint the same game, I'm going to keep them in the same file. I hide their data
-- from each other by using separate `do .. end` blocks and not setting any globals.

-- Remember that in ENet, the 'host' represents yourself on the network, while a 'peer' represents
-- someone else. So the server has one host and many peers (the clients), and each client has one
-- host and one peer (the server).


----------------------------------------------------------------------------------------------------
-- Server
----------------------------------------------------------------------------------------------------

local server = {}
do
    -- The shared state. This will be synced to all clients.
    local state = share.new('state')
    state:__autoSync(true)

    -- Initial state
    state.key = 'no key'
    state.x, state.y = 20, 20

    -- Network stuff
    local host -- The host
    local peers = {} -- Clients

    -- Start server
    function server.start()
        host = enet.host_create('*:22122')
    end

    function server.update(dt)
        -- Send state updates to everyone
        for peer in pairs(peers) do
            local diff = state:__diff(peer)
            if diff ~= nil then -- `nil` if nothing changed
                peer:send(marshal.encode(diff))
            end
        end
        state:__flush()

        -- Process network events
        if host then
            while true do
                local event = host:service(0)
                if not event then break end

                -- Someone connected?
                if event.type == 'connect' then
                    peers[event.peer] = true -- Remember this client
                    event.peer:send(marshal.encode(state:__diff(event.peer, true))) -- Send everything
                end

                -- Someone disconnected?
                if event.type == 'disconnect' then
                    peers[event.peer] = nil
                end
            end
        end
    end

    -- TODO(nikki): Actually listen for these on the client and send to server

    function server.keypressed(key)
        state.key = key
    end

    function server.mousepressed(x, y)
        state.x = x
        state.y = y
    end
end


----------------------------------------------------------------------------------------------------
-- Client
----------------------------------------------------------------------------------------------------

local client = {}
do
    -- View of server's shared state from this client. Initially `nil`.
    local state

    -- Network stuff
    local host -- The host
    local peer -- The server

    -- Connect to server
    function client.connect()
        host = enet.host_create()
        host:connect('127.0.0.1:22122')
    end

    function client.update(dt)
        -- Process network events
        if host then
            while true do
                local event = host:service(0)
                if not event then break end

                -- Connected?
                if event.type == 'connect' then
                    peer = event.peer
                end

                -- Received state diff?
                if event.type == 'receive' then
                    local diff = marshal.decode(event.data)
                    print('received', serpent.block(diff)) -- Print the diff, for debugging
                    state = share.apply(state, diff)
                end
            end
        end
    end

    function client.draw()
        if state then -- Initially state is `nil` so guard for that
            -- Draw key name at position
            love.graphics.print(state.key, state.x, state.y)
        end
    end

    function client.keypressed()
    end

    function client.mousepressed(x, y, button)
    end
end


----------------------------------------------------------------------------------------------------
-- Forwarding Love events to Server and Client
----------------------------------------------------------------------------------------------------

function love.update(dt)
    server.update(dt)
    client.update(dt)
end

function love.draw()
    client.draw()
end

function love.keypressed(key)
    if key == '1' then
        server.start()
    end
    if key == '2' then
        client.connect()
    end

    server.keypressed(key)
    client.keypressed(key)
end

function love.mousepressed(x, y, button)
    server.mousepressed(x, y, button)
    client.mousepressed(x, y, button)
end

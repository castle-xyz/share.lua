local share = require 'share'


local enet = require 'enet' -- Network
local marshal = require 'marshal' -- Serialization
local serpent = require 'https://raw.githubusercontent.com/pkulchenko/serpent/522a6239f25997b101c585c0daf6a15b7e37fad9/src/serpent.lua' -- Table printing


-- Super basic example where you can press keys to show the key name on the screen, and click with
-- the mouse to change where it's displayed.
--
-- Press 0 to start the server. Click to connect the client (allows connecting by touch on mobile).
--
-- To try connecting as a client to a remote server, start the server there by pressing 0. Edit
-- the line that says "EDIT IP ADDRESS FOR REMOTE SERVER" below to contain the ip address of that
-- computer. Run the edited code on the client and click.

-- You could write server and client code each in separate files and that probably helps make it
-- clear what's visible to what. But to keep the repo clean and allow testing server-client
-- connection within the same game, I'm going to keep them in the same file. I hide their data
-- from each other by using separate `do .. end` blocks and not setting any globals.

-- Remember that in ENet, the 'host' represents yourself on the network, while a 'peer' represents
-- someone else. So the server has one host and many peers (the clients), and each client has one
-- host and one peer (the server).


----------------------------------------------------------------------------------------------------
-- Server
----------------------------------------------------------------------------------------------------

local server = {}
do
    server.started = false -- Export started state for use below

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
        server.started = true
    end

    function server.update(dt)
        -- Send state updates to everyone
        for peer in pairs(peers) do
            local diff = state:__diff(peer)
            if diff ~= nil then -- `nil` if nothing changed
                peer:send(marshal.encode(diff))
            end
        end
        state:__flush() -- Make sure to reset diff state after sending!

        -- Process network events
        if host then
            while true do
                local event = host:service(0)
                if not event then break end

                -- Someone connected?
                if event.type == 'connect' then
                    peers[event.peer] = true -- Remember this client
                    -- `true` below is for 'exact' -- send full state on connect, not just a diff
                    event.peer:send(marshal.encode(state:__diff(event.peer, true)))
                end

                -- Someone disconnected?
                if event.type == 'disconnect' then
                    peers[event.peer] = nil
                end

                -- Received a request?
                if event.type == 'receive' then
                    local request = marshal.decode(event.data)

                    -- Keypress?
                    if request.type == 'keypressed' then
                        state.key = request.key
                    end

                    -- Mousepress?
                    if request.type == 'mousepressed' then
                        state.x, state.y = request.x, request.y
                    end
                end
            end
        end
    end
end


----------------------------------------------------------------------------------------------------
-- Client
----------------------------------------------------------------------------------------------------

local client = {}
do
    client.connected = false -- Export connected state for use below

    -- View of server's shared state from this client. Initially `nil`.
    local state

    -- Network stuff
    local host -- The host
    local peer -- The server

    -- Connect to server
    function client.connect()
        host = enet.host_create()
        host:connect('127.0.0.1:22122') -- EDIT IP ADDRESS FOR REMOTE SERVER
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
                    client.connected = true
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
        if state then -- `nil` till we receive first update, so guard for that
            -- Draw key name at position
            love.graphics.print(state.key, state.x, state.y)
        end
    end

    function client.keypressed(key)
        if peer then -- `nil` till we connect, so guard for that
            -- Send keypress request to server
            peer:send(marshal.encode({ type = 'keypressed', key = key }))
        end
    end

    function client.mousepressed(x, y, button)
        if peer then -- `nil` till we connect, so guard for that
            -- Send mousepress request to server
            peer:send(marshal.encode({ type = 'mousepressed', x = x, y = y }))
        end
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
    if not server.started and key == '0' then
        server.start()
    end

    client.keypressed(key)
end

function love.mousepressed(x, y, button)
    if not client.connected then
        client.connect()
    end
    client.mousepressed(x, y, button)
end

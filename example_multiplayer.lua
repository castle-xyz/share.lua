local state = require 'state'


local enet = require 'enet' -- Network
local marshal = require 'marshal' -- Serialization
local serpent = require 'https://raw.githubusercontent.com/pkulchenko/serpent/522a6239f25997b101c585c0daf6a15b7e37fad9/src/serpent.lua' -- Table printing


----------------------------------------------------------------------------------------------------
-- Server
----------------------------------------------------------------------------------------------------

local server = {}
do
    server.started = false -- Export started share for use below

    -- The shared state. This will be synced to all clients.
    local share = state.new()
    share:__autoSync(true)

    -- Initial share
    share.key = 'no key'
    share.x, share.y = 20, 20

    -- Network stuff
    local host -- The host
    local peers = {} -- Clients

    -- Start server
    function server.start()
        host = enet.host_create('*:22122')
        server.started = true
    end

    function server.update(dt)
        -- Send share updates to everyone
        for peer in pairs(peers) do
            local diff = share:__diff(peer)
            if diff ~= nil then -- `nil` if nothing changed
                peer:send(marshal.encode(diff))
            end
        end
        share:__flush() -- Make sure to reset diff share after sending!

        -- Process network events
        if host then
            while true do
                local event = host:service(0)
                if not event then break end

                -- Someone connected?
                if event.type == 'connect' then
                    peers[event.peer] = true -- Remember this client
                    -- `true` below is for 'exact' -- send full share on connect, not just a diff
                    event.peer:send(marshal.encode(share:__diff(event.peer, true)))
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
                        share.key = request.key
                    end

                    -- Mousepress?
                    if request.type == 'mousepressed' then
                        share.x, share.y = request.x, request.y
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
    client.connected = false -- Export connected share for use below

    -- View of server's stated share from this client. Initially `nil`.
    local share

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

                -- Received share diff?
                if event.type == 'receive' then
                    local diff = marshal.decode(event.data)
                    print('received', serpent.block(diff)) -- Print the diff, for debugging
                    share = state.apply(share, diff)
                end
            end
        end
    end

    function client.draw()
        if share then -- `nil` till we receive first update, so guard for that
            -- Draw key name at position
            love.graphics.print(share.key, share.x, share.y)
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

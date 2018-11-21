local state = require 'state'


local enet = require 'enet' -- Network
local marshal = require 'marshal' -- Serialization


local server = {}
do
    server.enabled = false
    server.started = false

    local share = state.new()
    share:__autoSync(true)
    server.share = share
    local boxes = {}
    server.boxes = {}

    local host
    local peers = {}
    local nextId = 1

    function server.start(port)
        host = enet.host_create('*:' .. tostring(port or '22122'))
        if host == nil then
            error("couldn't start server -- is port in use?")
        end
        host:compress_with_range_coder()
        server.started = true
    end

    function server.update(dt)
        -- Send state updates to everyone
        for peer in pairs(peers) do
            local diff = share:__diff(peer)
            if diff ~= nil then -- `nil` if nothing changed
                peer:send(marshal.encode({ diff = diff }))
            end
        end
        share:__flush() -- Make sure to reset diff state after sending!

        -- Process network events
        if host then
            while true do
                local event = host:service(0)
                if not event then break end

                -- Someone connected?
                if event.type == 'connect' then
                    local id = nextId
                    nextId = nextId + 1
                    peers[event.peer] = { id = id }
                    boxes[id] = {}
                    if server.connect then
                        server.connect(id)
                    end
                    event.peer:send(marshal.encode({
                        id = id,
                        exact = share:__diff(event.peer, true),
                    }))
                end

                -- Someone disconnected?
                if event.type == 'disconnect' then
                    local id = peers[event.peer].id
                    if server.disconnect then
                        server.disconnect(id)
                    end
                    boxes[id] = nil
                    peers[event.peer] = nil
                end

                -- Received a request?
                if event.type == 'receive' then
                    local id = peers[event.peer].id
                    local request = marshal.decode(event.data)

                    -- Message?
                    if request.message then
                        if server.receive then
                            server.receive(id, unpack(request.message, 1, request.message.nArgs))
                        end
                    end

                    -- Diff / exact?
                    if request.diff then
                        if server.changing then
                            server.changing(id, request.diff)
                        end
                        assert(state.apply(boxes[id], request.diff) == boxes[id])
                        if server.changed then
                            server.changed(id, request.diff)
                        end
                    end
                    if request.exact then -- `state.apply` may return a new value
                        if server.changing then
                            server.changing(id, request.exact)
                        end
                        local box = boxes[id]
                        local new = state.apply(box, request.exact)
                        for k, v in pairs(new) do
                            box[k] = v
                        end
                        for k in pairs(box) do
                            if not new[k] then
                                box[k] = nil
                            end
                        end
                        if server.changed then
                            server.changed(id, request.exact)
                        end
                    end
                end
            end
        end
    end
end


local client = {}
do
    client.enabled = false
    client.connected = false
    client.id = nil

    local share = {}
    client.share = share
    local box = state.new()
    box:__autoSync(true)

    local host
    local peer

    function client.start(address)
        host = enet.host_create()
        host:compress_with_range_coder()
        host:connect(address or '127.0.0.1:22122')
    end

    function client.send(...)
        if peer then
            peer:send({ message = { nArgs = select('#', ...), ... } })
        end
    end

    function client.update(dt)
        -- Send state updates to server
        if peer then
            local diff = box:__diff(peer)
            if diff ~= nil then -- `nil` if nothing changed
                peer:send(marshal.encode({ diff = diff }))
            end
        end
        box:__flush() -- Make sure to reset diff state after sending!

        -- Process network events
        if host then
            while true do
                local event = host:service(0)
                if not event then break end

                -- Server connected?
                if event.type == 'connect' then
                    -- Ignore this, wait till we receive id (see below)
                end

                -- Server disconnected?
                if event.type == 'disconnect' then
                    if client.disconnect then
                        client.disconnect()
                    end
                end

                -- Received a request?
                if event.type == 'receive' then
                    local request = marshal.decode(event.data)

                    -- Diff / exact? (do this first so we have it in `.connect` below)
                    if request.diff then
                        if client.changing then
                            client.changing(request.diff)
                        end
                        assert(state.apply(share, request.diff) == share)
                        if client.changed then
                            client.changed(request.diff)
                        end
                    end
                    if request.exact then -- `state.apply` may return a new value
                        if client.changing then
                            client.changing(request.exact)
                        end
                        local new = state.apply(share, request.exact)
                        for k, v in pairs(new) do
                            share[k] = v
                        end
                        for k in pairs(share) do
                            if not new[k] then
                                share[k] = nil
                            end
                        end
                        if client.changed then
                            client.changed(request.exact)
                        end
                    end

                    -- Id?
                    if request.id then
                        peer = event.peer
                        client.connected = true
                        client.id = request.id
                        if client.connect then
                            client.connect()
                        end
                        peer:send(marshal.encode({ exact = box:__diff(peer, true) }))
                    end
                end
            end
        end
    end
end


local loveCbs = {
    load = { server = true, client = true },
    lowmemory = { server = true, client = true },
    quit = { server = true, client = true },
    threaderror = { server = true, client = true },
    update = { server = true, client = true },
    directorydropped = { client = true },
    draw = { client = true },
    --    errhand = { client = true },
    --    errorhandler = { client = true },
    filedropped = { client = true },
    focus = { client = true },
    keypressed = { client = true },
    keyreleased = { client = true },
    mousefocus = { client = true },
    mousemoved = { client = true },
    mousepressed = { client = true },
    mousereleased = { client = true },
    resize = { client = true },
    --    run = { client = true },
    textedited = { client = true },
    textinput = { client = true },
    touchmoved = { client = true },
    touchpressed = { client = true },
    touchreleased = { client = true },
    visible = { client = true },
    wheelmoved = { client = true },
    gamepadaxis = { client = true },
    gamepadpressed = { client = true },
    gamepadreleased = { client = true },
    joystickadded = { client = true },
    joystickaxis = { client = true },
    joystickhat = { client = true },
    joystickpressed = { client = true },
    joystickreleased = { client = true },
    joystickremoved = { client = true },
}

for cbName, where in pairs(loveCbs) do
    love[cbName] = function(...)
        if where.server and server.enabled then
            local serverCb = server[cbName]
            if serverCb then
                serverCb(...)
            end
        end
        if where.client and client.enabled then
            local clientCb = client[cbName]
            if clientCb then
                clientCb(...)
            end
        end
    end
end


return {
    server = server,
    client = client,
    DIFF_NIL = state.DIFF_NIL,
}

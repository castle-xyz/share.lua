local share = require 'share'


local enet = require 'enet'


local server = {}
do
    local host

    function server.start()
        host = enet.host_create('*:22122')
    end

    function server.update(dt)
        if host then
            while true do
                local event = host:service(0)
                if not event then break end

                if event.type == 'connect' then
                    event.peer:send('hai')
                end
            end
        end
    end
end


local client = {}
do
    local host

    function client.connect()
        host = enet.host_create()
        host:connect('127.0.0.1:22122')
    end

    function client.update(dt)
        if host then
            while true do
                local event = host:service(0)
                if not event then break end

                if event.type == 'receive' then
                    print('client got msg: ' .. event.data)
                end
            end
        end
    end

    function client.draw()
    end
end


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
end

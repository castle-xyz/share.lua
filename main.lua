local share = require 'share'

--share.foo = {
--    bar = 3,
--    baz = {
--        kek = 'hai',
--        lmao = 123,
--    },
--    arr = { 1, 2, 3 },
--}
--
--share.foo.kek = 7
--share.ayo = 8
--share.foo.baz.lmao = share.foo.baz.lmao + 1
--
--print(serpent.block(share:__flush()))
--local foo = share.foo
--share.foo = nil
--share.kek = foo
--share.kek.baz:__sync()
--print(serpent.block(share:__flush()))
--
--for k, v in pairs({ a = 1, b = 2}) do
--    print(k, tostring(v))
--end
--
--for k, v in pairs(share.kek) do
--    print(k, tostring(v))
--end
--
--for i = 1, #share.kek.arr do
--    print(share.kek.arr[i])
--end



share:__autoSync(true)

share.foo = {
    bar = 3,
    baz = 42,
    blah = {
        hello = 1,
        world = 'ok',
    }
}

print(serpent.block(share:__flush()))
print(serpent.block(share:__flush()))

share.baz = 76

print(serpent.block(share:__flush()))

share.blah = 13 -- overwriting table with number

print(serpent.block(share:__flush()))



--share:__autoSync(true)
--
--share.entities = {}
--local entities = share.entities
--
--for i = 1, 20000 do
--    entities[i] = { x = math.random(), y = math.random() }
--end
--
--function love.update(dt)
--    for i = 1, 10 do
--        local ent = entities[math.random(#entities)]
--        ent.x = ent.x + 20 * dt
--    end
----    print(serpent.block(share:__flush()))
--end
--
--function love.draw()
--    love.graphics.print('fps: ' .. love.timer.getFPS(), 20, 20)
--end



--share.foo = {
--    bar = { a = 1, b = 2, c = { 1, 2, 3 } },
--    baz = { a = 1, b = 2, c = { 1, 2, 3 } },
--    kek = 'hai',
--}
--share.foo:__sync()
--print(serpent.block(share:__flush()))
--share.foo.bar:__sync()
--print(serpent.block(share:__flush()))
--share.foo.bar.c:__sync()
--share.foo.baz.c:__sync()
--print(serpent.block(share:__flush()))

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
}
print(serpent.block(share:__flush()))
share.foo.bar = 3
share.foo.lmao = 42
share.foo.baz = 93
share.foo = share.foo
print(serpent.block(share:__flush()))

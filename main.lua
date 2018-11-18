local share = require 'share'

share.foo = {
    bar = 3,
    baz = {
        kek = 'hai',
        lmao = 123,
    },
    arr = { 1, 2, 3 },
}

share.foo.kek = 7
share.ayo = 8
share.foo.baz.lmao = share.foo.baz.lmao + 1

print(serpent.block(share:__flush()))
local foo = share.foo
share.foo = nil
share.kek = foo
share.kek.baz:__sync()
print(serpent.block(share:__flush()))

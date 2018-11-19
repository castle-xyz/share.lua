local share = require 'share'


-- Make LuaUnit think nodes are tables, also give it the right `table.unpack` function
local oldType = type
function type(t)
    if oldType(t) == 'userdata' and t.__isNode then return 'table' end
    return oldType(t)
end
table.unpack = unpack
local lu = require 'https://raw.githubusercontent.com/bluebird75/luaunit/7a441a5b97b5e50c4121907b2a92ae45d31d630a/luaunit.lua'


-- A little utility to make and track tests
local allTestNames = {}
local function defTest(name, func)
    assert(name:match('^test'), "test names must start wth 'test'")
    _G[name] = func
    table.insert(allTestNames, name)
end

-- Generate a deep table, branching `nKeys`-ways at each level, with max depth `depth`
local function genTable(nKeys, depth)
    if depth <= 0 then return math.random(10000) end
    local t = {}
    for i = 1, nKeys do
        t[math.random() < 0.5 and i or tostring(i)] = genTable(nKeys, depth - math.random(depth - 1))
    end
    return t
end

-- Edit a deep table
local function editTable(t)
    for k, v in pairs(t) do
        if type(v) == 'table' then
            editTable(v)
        end

        local r = math.random(5)
        if r <= 1 then
            t[k] = nil
        elseif r <= 3 then
            t[k] = math.random(10000)
        end
    end
end


-- Assignment
defTest('testAssign', function()
    local root = share.new()

    -- Initial deep table
    local t = {
        bar = 3,
        baz = 42,
        blah = {
            hello = 1,
            world = 'ok',
        }
    }
    root.t = t
    lu.assertEquals(root.t, t)

    -- Basic overwrite
    root.t.newKey = 4
    lu.assertEquals(root.t.newKey, 4)

    -- Deep random table
    for i = 1, 10 do
        local u = genTable(5, 2)
        root.t.u = u
        lu.assertEquals(root.t.u, u)
    end
end)


-- Manual sync
defTest('testSync', function()
    local root = share.new()

    -- Initial table
    root.a = {
        b = { 1, 2, 3 },
        c = { 4, 5, 6 },
        d = { hello = 2, world = 5 },
    }

    -- Sync leaf
    root.a.d:__sync('hello')
    lu.assertEquals(root:__flush(), { a = { d = { hello = 2 }}})

    -- Sync sub-table
    root.a.c:__sync()
    lu.assertEquals(root:__flush(), { a = { c = { __exact = true, 4, 5, 6 } } })

    -- Sync recursive
    root.a:__sync()
    lu.assertEquals(root:__flush(), {
        a = {
            __exact = true,
            b = { 1, 2, 3 },
            c = { 4, 5, 6 },
            d = { hello = 2, world = 5 },
        },
    })
end)


-- Auto-sync
defTest('testAutoSync', function()
    local root = share.new()
    root:__autoSync(true)

    -- Initial table
    root.a = {
        b = { 1, 2, 3 },
        c = { 4, 5, 6 },
        d = { hello = 2, world = 5 },
        e = { hey = 2, there = { deeper = 42 } },
    }
    lu.assertEquals(root:__flush(), {
        a = {
            __exact = true,
            b = { 1, 2, 3 },
            c = { 4, 5, 6 },
            d = { hello = 2, world = 5 },
            e = { hey = 2, there = { deeper = 42 } },
        },
    })

    -- Sync leaf
    root.a.d.hello = 3
    lu.assertEquals(root:__flush(), { a = { d = { hello = 3 }}})

    -- Sync sub-table
    root.a.c = { 7, 8, 9 }
    lu.assertEquals(root:__flush(), { a = { c = { __exact = true, 7, 8, 9 } } })

    -- Sync separate paths
    root.a.d.world = 6
    root.a.e.there = 'nope'
    lu.assertEquals(root:__flush(), { a = { d = { world = 6 }, e = { there = 'nope' } } })
end)


-- Apply with auto-sync
defTest('testAutoApply', function()
    local root = share.new()
    root:__autoSync(true)
    local target = {}

    -- Initial table
    root.a = {
        b = { 1, 2, 3 },
        c = { 4, 5, 6 },
        d = { hello = 2, world = 5 },
        e = { hey = 2, there = { deeper = 42 } },
    }
    share.apply(target, root:__flush())
    lu.assertEquals(target, root)

    -- Leaf
    root.a.d.hello = 3
    share.apply(target, root:__flush())
    lu.assertEquals(target, root)

    -- Sub-table
    root.a.c = { 7, 8, 9 }
    share.apply(target, root:__flush())
    lu.assertEquals(target, root)

    -- Separate paths
    root.a.d.world = 6
    root.a.e.there = 'nope'
    share.apply(target, root:__flush())
    lu.assertEquals(target, root)

    -- `nil`
    root.a.d.world = 6
    root.a.d = nil
    root.a.e.there = nil
    share.apply(target, root:__flush())
    lu.assertEquals(target, root)

    -- Generative
    for i = 1, 2 do
        root.u = genTable(2, 2)
        share.apply(target, root:__flush())
        lu.assertEquals(target, root)
        for j = 1, 1 do
            editTable(root.u)
            share.apply(target, root:__flush())
            lu.assertEquals(target, root)
        end
    end
end)


lu.LuaUnit:runSuiteByNames(allTestNames)

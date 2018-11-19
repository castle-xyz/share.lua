local share = require 'share'


-- Randomly generate a deep table, branching `nKeys`-ways at each level, with max depth `depth`
local function genTable(nKeys, depth)
    if depth <= 0 then return math.random(10000) end
    local t = {}
    for i = 1, nKeys do
        t[math.random() < 0.5 and i or tostring(i)] = genTable(nKeys, depth - math.random(depth - 1))
    end
    return t
end

-- Randomly edit a deep table
local function editTable(t)
    for k, v in pairs(t) do
        if type(v) == 'table' then -- Edit inside first so we can test overwriting
            editTable(v)
        end

        local r = math.random(5)
        if r <= 1 then
            t[k] = nil
        elseif r <= 3 then
            t[k] = math.random(10000)
        elseif r <= 4 then
            t[k] = genTable(2, 2)
        end
    end
end

-- Compare tables for deep equality, returning whether equal and along with a helpful message if not
local function deep(x) return type(x) == 'table' or type(x) == 'userdata' and x.__isNode end
local function equal(a, b)
    if a == b then return true end
    if not (deep(a) and deep(b)) then
        return false, ' ' .. tostring(a) .. ' ~= ' .. tostring(b)
    end
    for k, v in pairs(a) do
        local result, msg = equal(v, b[k])
        if not result then
            return false, tostring(k) .. ':' .. msg
        end
    end
    for k, v in pairs(b) do
        if a[k] == nil then -- All keys in `a` were already checked above
            return false, tostring(k) .. ': nil ~= ' .. tostring(v)
        end
    end
    return true
end


-- Assignment
local function testBasic()
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
    assert(equal(root.t, t))

    -- Basic overwrite
    root.t.newKey = 4
    assert(equal(root.t.newKey, 4))

    -- Deep random table
    for i = 1, 10 do
        local u = genTable(5, 2)
        root.t.u = u
        assert(equal(root.t.u, u))
    end
end


-- Manual sync
local function testSync()
    local root = share.new()

    -- We do `:__diff` a couple times to check that it's not lost without `:__flush`

    -- Initial table
    root.a = {
        b = { 1, 2, 3 },
        c = { 4, 5, 6 },
        d = { hello = 2, world = 5 },
    }

    -- Sync leaf
    root.a.d:__sync('hello')
    assert(equal(root:__diff(), { a = { d = { hello = 2 }}}))
    assert(equal(root:__flush(true), { a = { d = { hello = 2 }}}))

    -- Sync sub-table
    root.a.c:__sync()
    assert(equal(root:__diff(), { a = { c = { __exact = true, 4, 5, 6 } } }))
    assert(equal(root:__diff(), { a = { c = { __exact = true, 4, 5, 6 } } }))
    assert(equal(root:__flush(true), { a = { c = { __exact = true, 4, 5, 6 } } }))

    -- Sync recursive
    root.a:__sync()
    assert(equal(root:__diff(), {
        a = {
            __exact = true,
            b = { 1, 2, 3 },
            c = { 4, 5, 6 },
            d = { hello = 2, world = 5 },
        },
    }))
    assert(equal(root:__flush(true), {
        a = {
            __exact = true,
            b = { 1, 2, 3 },
            c = { 4, 5, 6 },
            d = { hello = 2, world = 5 },
        },
    }))
end


-- Auto-sync
local function testAutoSync()
    local root = share.new()
    root:__autoSync(true)

    -- Initial table
    root.a = {
        b = { 1, 2, 3 },
        c = { 4, 5, 6 },
        d = { hello = 2, world = 5 },
        e = { hey = 2, there = { deeper = 42 } },
    }
    assert(equal(root:__diff(), {
        a = {
            __exact = true,
            b = { 1, 2, 3 },
            c = { 4, 5, 6 },
            d = { hello = 2, world = 5 },
            e = { hey = 2, there = { deeper = 42 } },
        },
    }))
    assert(equal(root:__flush(true), {
        a = {
            __exact = true,
            b = { 1, 2, 3 },
            c = { 4, 5, 6 },
            d = { hello = 2, world = 5 },
            e = { hey = 2, there = { deeper = 42 } },
        },
    }))

    -- Sync leaf
    root.a.d.hello = 3
    assert(equal(root:__diff(), { a = { d = { hello = 3 }}}))
    assert(equal(root:__flush(true), { a = { d = { hello = 3 }}}))

    -- Sync sub-table
    root.a.c = { 7, 8, 9 }
    assert(equal(root:__diff(), { a = { c = { __exact = true, 7, 8, 9 } } }))
    assert(equal(root:__diff(), { a = { c = { __exact = true, 7, 8, 9 } } }))
    assert(equal(root:__flush(true), { a = { c = { __exact = true, 7, 8, 9 } } }))

    -- Sync separate paths
    root.a.d.world = 6
    root.a.e.there = 'nope'
    assert(equal(root:__diff(), { a = { d = { world = 6 }, e = { there = 'nope' } } }))
    assert(equal(root:__flush(true), { a = { d = { world = 6 }, e = { there = 'nope' } } }))
end


-- Auto-sync with relevance
local function testAutoSyncRelevance()
    local root = share.new()
    root:__autoSync(true)

    local isRelevant = true

    -- Just use client ids as keys for ease in testing

    -- Init
    root.t = {
        rel = {
            a = { 'a' },
            b = { 'b' },
            c = { 'c' },
        },
        norm = { 1, 2, 3 },
    }
    root.t.rel:__relevance(function (node, client)
        return isRelevant and { [client] = true } or {}
    end)

    -- a and b enter
    assert(equal(root:__diff('a'), {
        t = {
            rel = { __relevance = true, a = { __exact = true, 'a' } },
            norm = { __exact = true, 1, 2, 3 },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { __relevance = true, b = { __exact = true, 'b' } },
            norm = { __exact = true, 1, 2, 3 },
        }
    }))
    root:__flush()

    -- Update
    root.t.rel.a[2] = 2
    root.t.rel.b[2] = 2
    assert(equal(root:__diff('a'), {
        t = {
            rel = { __relevance = true, a = { [2] = 2 } },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { __relevance = true, b = { [2] = 2 } },
        }
    }))
    root:__flush()

    -- Make irrelevant
    isRelevant = false
    root.t:__sync('rel')
    assert(equal(root:__diff('a'), {
        t = {
            rel = { __relevance = true },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { __relevance = true },
        }
    }))
    root:__flush()

    -- Make relevant again
    isRelevant = true
    root.t:__sync('rel')
    assert(equal(root:__diff('a'), {
        t = {
            rel = { __relevance = true, a = { __exact = true, 'a', 2 } },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { __relevance = true, b = { __exact = true, 'b', 2 } },
        }
    }))
    root:__flush()

    -- Update with a non-relevance update too
    root.t.rel.a[3] = 3
    root.t.rel.b[3] = 3
    root.t.norm[4] = 4
    assert(equal(root:__diff('a'), {
        t = {
            rel = { __relevance = true, a = { [3] = 3 } },
            norm = { [4] = 4 },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { __relevance = true, b = { [3] = 3 } },
            norm = { [4] = 4 },
        }
    }))
    root:__flush()
    assert(equal(root:__diff('a'), {}))
end

-- Apply with auto-sync
local function testAutoApply()
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
    share.apply(target, root:__flush(true))
    assert(equal(target, root))

    -- Leaf
    root.a.d.hello = 3
    share.apply(target, root:__flush(true))
    assert(equal(target, root))

    -- Sub-table
    root.a.c = { 7, 8, 9 }
    share.apply(target, root:__flush(true))
    assert(equal(target, root))

    -- Separate paths
    root.a.d.world = 6
    root.a.e.there = 'nope'
    share.apply(target, root:__flush(true))
    assert(equal(target, root))

    -- `nil`
    root.a.d.world = 6
    root.a.d = nil
    root.a.e.there = nil
    share.apply(target, root:__flush(true))
    assert(equal(target, root))

    -- Generative
    for i = 1, 5 do
        root.u = genTable(5, 4)
        share.apply(target, root:__flush(true))
        assert(equal(target, root))
        for j = 1, 5 do
            editTable(root.u)
            share.apply(target, root:__flush(true))
            assert(equal(target, root))
        end
    end
end


testBasic()
testSync()
testAutoSync()
testAutoSyncRelevance()
testAutoApply()


print('no errors? then everything passed...')

local state = require 'state'


--local serpent = require 'https://raw.githubusercontent.com/pkulchenko/serpent/522a6239f25997b101c585c0daf6a15b7e37fad9/src/serpent.lua'


local DIFF_NIL = '__NIL' -- Sentinel to encode `nil`-ing in diffs -- TODO(nikki): Make this smaller


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
local function deep(x) return type(x) == 'table' or state.isState(x) end
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
    local root = state.new()

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
    local root = state.new()

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
    root.a.c:__sync(nil, true)
    assert(equal(root:__diff(), { a = { c = { __exact = true, 4, 5, 6 } } }))
    assert(equal(root:__diff(), { a = { c = { __exact = true, 4, 5, 6 } } }))
    assert(equal(root:__flush(true), { a = { c = { __exact = true, 4, 5, 6 } } }))

    -- Sync recursive
    root.a:__sync(nil, true)
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
    local root = state.new()
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
    assert(equal(root:__diff(), { a = { c = { 7, 8, 9 } } }))
    assert(equal(root:__diff(), { a = { c = { 7, 8, 9 } } }))
    assert(equal(root:__flush(true), { a = { c = { 7, 8, 9 } } }))

    -- Sync sub-table with no diff
    root.a.c = { 7, 8, 9 }
    assert(equal(root:__diff(), nil))
    assert(equal(root:__diff(), nil))
    assert(equal(root:__flush(true), nil))

    -- Sync sub-table with edit
    root.a.c = { 7, 8, { 'hello', 'world' } }
    assert(equal(root:__diff(), { a = { c = { [3] = { __exact = true, 'hello', 'world' } } }}))
    root:__flush()

    -- Sync sub-table with delete
    root.a.c = { 7, { 'hello', 'world' } }
    assert(equal(root:__diff(), { a = { c = { [2] = { __exact = true, 'hello', 'world' }, [3] = DIFF_NIL } }}))
    root:__flush()

    -- Sync sub-table with overwrite due to lots of additions
    root.a.c = { 7, { 'hello', 'world' }, 8, 9, 10, 11, 12, 13 }
    assert(equal(root:__diff(), { a = { c = { __exact = true, 7, { 'hello', 'world' }, 8, 9, 10, 11, 12, 13 } }}))
    root:__flush()

    -- Sync sub-table with overwrite due to lots of removals
    root.a.c = { 7 }
    assert(equal(root:__diff(), { a = { c = { __exact = true, 7 } }}))
    root:__flush()

    -- Sync separate paths
    root.a.d.world = 6
    root.a.e.there = 'nope'
    assert(equal(root:__diff(), { a = { d = { world = 6 }, e = { there = 'nope' } } }))
    assert(equal(root:__flush(true), { a = { d = { world = 6 }, e = { there = 'nope' } } }))

    -- Sync `nil`-ing
    root.a.d = nil
    assert(equal(root:__diff(), { a = { d = DIFF_NIL } }))
    assert(equal(root:__diff(), { a = { d = DIFF_NIL } }))
end


-- Auto-sync with relevance
local function testAutoSyncRelevance()
    local root = state.new()
    root:__autoSync(true)

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
    root.t.rel:__relevance(function (self, client) return { [client] = true } end)

    -- a and b enter
    assert(equal(root:__diff('a'), {
        t = {
            __exact = true,
            rel = { a = { 'a' } },
            norm = { 1, 2, 3 },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            __exact = true,
            rel = { b = { 'b' } },
            norm = { 1, 2, 3 },
        }
    }))
    root:__flush()

    -- Update
    root.t.rel.a[2] = 2
    root.t.rel.b[2] = 2
    assert(equal(root:__diff('a'), {
        t = {
            rel = { a = { [2] = 2 } },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { b = { [2] = 2 } },
        }
    }))
    root:__flush()

    -- Make irrelevant
    root.t.rel:__relevance(function (self, client) return {} end)
    root.t.rel:__sync()
    assert(equal(root:__diff('a'), {
        t = {
            rel = { a = DIFF_NIL },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { b = DIFF_NIL },
        }
    }))
    root:__flush()

    -- Make relevant again
    root.t.rel:__relevance(function (self, client) return { [client] = true } end)
    root.t.rel:__sync()
    assert(equal(root:__diff('a'), {
        t = {
            rel = { a = { __exact = true, 'a', 2 } },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { b = { __exact = true, 'b', 2 } },
        }
    }))
    root:__flush()

    -- Update with a non-relevance update too
    root.t.rel.a[3] = 3
    root.t.rel.b[3] = 3
    root.t.norm[4] = 4
    assert(equal(root:__diff('a'), {
        t = {
            rel = { a = { [3] = 3 } },
            norm = { [4] = 4 },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { b = { [3] = 3 } },
            norm = { [4] = 4 },
        }
    }))
    assert(root:__diff('a').t.norm == root:__diff('b').t.norm, 'use diff cache')
    root:__flush()

    -- No changes
    assert(equal(root:__diff('a'), nil))
    assert(equal(root:__diff('b'), nil))

    -- New client
    root.t.rel.d = { 'd' }
    assert(equal(root:__diff('a'), nil))
    assert(equal(root:__diff('b'), nil))
    assert(equal(root:__diff('d', true), {
        __exact = true,
        t = {
            rel = { d = { 'd' } },
            norm = { 1, 2, 3, 4 },
        }
    }))
    root:__flush()
    assert(equal(root:__diff('a'), nil))

    -- Update with `nil`-ing
    root.t.rel.a[3] = nil
    root.t.rel.b[3] = nil
    assert(equal(root:__diff('a'), {
        t = {
            rel = { a = { [3] = DIFF_NIL } },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { b = { [3] = DIFF_NIL } },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { b = { [3] = DIFF_NIL } },
        }
    }))
    root:__flush()

    -- Sharing with relevance
    root.t.rel:__relevance(function (node, client) return { a = true, b = true } end)
    root.t.rel:__sync()
    assert(equal(root:__diff('a'), {
        t = {
            rel = { b = { __exact = true, 'b', 2 } },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { a = { __exact = true, 'a', 2 } },
        }
    }))
    assert(equal(root:__diff('a'), {
        t = {
            rel = { b = { __exact = true, 'b', 2 } },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { a = { __exact = true, 'a', 2 } },
        }
    }))
    root:__flush()

    -- Sharing with relevance
    root.t.rel.a[7] = 7
    assert(equal(root:__diff('a'), {
        t = {
            rel = { a = { [7] = 7 } },
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            rel = { a = { [7] = 7 } },
        }
    }))
    assert(root:__diff('b').t.rel.a == root:__diff('a').t.rel.a, 'use diff cache')
    root:__flush()

    -- Outside stuff
    root.t.out = 3
    assert(equal(root:__diff('a'), {
        t = {
            out = 3,
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            out = 3,
        }
    }))
    root:__flush()

    root.t.out = nil
    assert(equal(root:__diff('a'), {
        t = {
            out = DIFF_NIL,
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            out = DIFF_NIL,
        }
    }))
    root:__flush()

    root.t.out = 3
    assert(equal(root:__diff('a'), {
        t = {
            out = 3,
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            out = 3,
        }
    }))
    root:__flush()

    root.t.out = nil
    assert(equal(root:__diff('a'), {
        t = {
            out = DIFF_NIL,
        }
    }))
    assert(equal(root:__diff('b'), {
        t = {
            out = DIFF_NIL,
        }
    }))
    root:__flush()
end


-- Apply with auto-sync
local function testAutoApply()
    local root = state.new()
    root:__autoSync(true)
    local target = {}

    -- Initial table
    root.a = {
        b = { 1, 2, 3 },
        c = { 4, 5, 6 },
        d = { hello = 2, world = 5 },
        e = { hey = 2, there = { deeper = 42 } },
    }
    state.apply(target, root:__flush(true))
    assert(equal(target, root))

    -- Leaf
    root.a.d.hello = 3
    state.apply(target, root:__flush(true))
    assert(equal(target, root))

    -- Sub-table
    root.a.c = { 7, 8, 9 }
    state.apply(target, root:__flush(true))
    assert(equal(target, root))

    -- Separate paths
    root.a.d.world = 6
    root.a.e.there = 'nope'
    state.apply(target, root:__flush(true))
    assert(equal(target, root))

    -- `nil`
    root.a.d.world = 6
    root.a.d = nil
    root.a.e.there = nil
    state.apply(target, root:__flush(true))
    assert(equal(target, root))

    -- Containing `dirtyRec` table
    root.f = {}
    root.f.g = { r = 10 }
    state.apply(target, root:__flush(true))
    assert(equal(target, root))
    root.f.g.r = 20
    state.apply(target, root:__flush(true))
    assert(equal(target, root))

    -- Generative
    for i = 1, 20 do
        root.u = genTable(8, 7)
        state.apply(target, root:__flush(true))
        assert(equal(target, root))
        for j = 1, 30 do
            editTable(root.u)
            state.apply(target, root:__flush(true))
            assert(equal(target, root))
        end
    end
end


-- Apply with auto-sync and relevance
local function testAutoApplyRelevance()
    local root = state.new()
    root:__autoSync(true)

    root.world = {
        rel = {
            -- Each of these is relevant to client `c` only if it contains `[c] = true` init
            [1] = { a = true, b = true },
            [2] = { a = true },
            [3] = { b = true },
        }
    }
    root.world.rel:__relevance(function(self, client)
        local ret = {}
        for k, v in pairs(self) do
            if v[client] then
                ret[k] = true
            end
        end
        return ret
    end)

    -- New clients
    local targetA, targetB = {}, {}
    targetA = state.apply(targetA, root:__diff('a', true))
    targetB = state.apply(targetB, root:__diff('b', true))
    root:__flush()
    assert(equal(targetA, {
        world = {
            rel = {
                [1] = { a = true, b = true },
                [2] = { a = true },
            }
        }
    }))
    assert(equal(targetB, {
        world = {
            rel = {
                [1] = { a = true, b = true },
                [3] = { b = true },
            }
        }
    }))

    -- No change
    state.apply(targetA, root:__diff('a'))
    state.apply(targetB, root:__diff('b'))
    root:__flush()
    assert(equal(targetA, {
        world = {
            rel = {
                [1] = { a = true, b = true },
                [2] = { a = true },
            }
        }
    }))
    assert(equal(targetB, {
        world = {
            rel = {
                [1] = { a = true, b = true },
                [3] = { b = true },
            }
        }
    }))

    -- New 'entity'
    root.world.rel[4] = { a = true, b = true }
    state.apply(targetA, root:__diff('a'))
    state.apply(targetB, root:__diff('b'))
    root:__flush()
    assert(equal(targetA, {
        world = {
            rel = {
                [1] = { a = true, b = true },
                [2] = { a = true },
                [4] = { a = true, b = true },
            }
        }
    }))
    assert(equal(targetB, {
        world = {
            rel = {
                [1] = { a = true, b = true },
                [3] = { b = true },
                [4] = { a = true, b = true },
            }
        }
    }))

    -- Entity became relevant
    root.world.rel[2].b = true
    state.apply(targetA, root:__diff('a'))
    state.apply(targetB, root:__diff('b'))
    root:__flush()
    assert(equal(targetA, {
        world = {
            rel = {
                [1] = { a = true, b = true },
                [2] = { a = true, b = true },
                [4] = { a = true, b = true },
            }
        }
    }))
    assert(equal(targetB, {
        world = {
            rel = {
                [1] = { a = true, b = true },
                [2] = { a = true, b = true },
                [3] = { b = true },
                [4] = { a = true, b = true },
            }
        }
    }))

    -- Entity became irrelevant
    root.world.rel[4].b = nil
    state.apply(targetA, root:__diff('a'))
    state.apply(targetB, root:__diff('b'))
    root:__flush()
    assert(equal(targetA, {
        world = {
            rel = {
                [1] = { a = true, b = true },
                [2] = { a = true, b = true },
                [4] = { a = true  },
            }
        }
    }))
    assert(equal(targetB, {
        world = {
            rel = {
                [1] = { a = true, b = true },
                [2] = { a = true, b = true },
                [3] = { b = true },
            }
        }
    }))
end


-- Apply with auto-sync and relevance at root
local function testAutoApplyRelevanceAtRoot()
    local root = state.new()
    root:__autoSync(true)

    root[1] = { a = true, b = true }
    root[2] = { a = true }
    root[3] = { b = true }

    root:__relevance(function(self, client)
        local ret = {}
        for k, v in pairs(self) do
            if v[client] then
                ret[k] = true
            end
        end
        return ret
    end)

    -- New clients
    local targetA, targetB = {}, {}
    targetA = state.apply(targetA, root:__diff('a', true))
    targetB = state.apply(targetB, root:__diff('b', true))
    root:__flush()
    assert(equal(targetA, {
        [1] = { a = true, b = true },
        [2] = { a = true },
    }))
    assert(equal(targetB, {
        [1] = { a = true, b = true },
        [3] = { b = true },
    }))

    -- No change
    state.apply(targetA, root:__diff('a'))
    state.apply(targetB, root:__diff('b'))
    root:__flush()
    assert(equal(targetA, {
        [1] = { a = true, b = true },
        [2] = { a = true },
    }))
    assert(equal(targetB, {
        [1] = { a = true, b = true },
        [3] = { b = true },
    }))

    -- New 'entity'
    root[4] = { a = true, b = true }
    state.apply(targetA, root:__diff('a'))
    state.apply(targetB, root:__diff('b'))
    root:__flush()
    assert(equal(targetA, {
        [1] = { a = true, b = true },
        [2] = { a = true },
        [4] = { a = true, b = true },
    }))
    assert(equal(targetB, {
        [1] = { a = true, b = true },
        [3] = { b = true },
        [4] = { a = true, b = true },
    }))

    -- Entity became relevant
    root[2].b = true
    state.apply(targetA, root:__diff('a'))
    state.apply(targetB, root:__diff('b'))
    root:__flush()
    assert(equal(targetA, {
        [1] = { a = true, b = true },
        [2] = { a = true, b = true },
        [4] = { a = true, b = true },
    }))
    assert(equal(targetB, {
        [1] = { a = true, b = true },
        [2] = { a = true, b = true },
        [3] = { b = true },
        [4] = { a = true, b = true },
    }))

    -- Entity became irrelevant
    root[4].b = nil
    state.apply(targetA, root:__diff('a'))
    state.apply(targetB, root:__diff('b'))
    root:__flush()
    assert(equal(targetA, {
        [1] = { a = true, b = true },
        [2] = { a = true, b = true },
        [4] = { a = true  },
    }))
    assert(equal(targetB, {
        [1] = { a = true, b = true },
        [2] = { a = true, b = true },
        [3] = { b = true },
    }))
end


-- Relevance with nesting
local function testAutoApplyRelevanceNested()
    local root = state.new()
    root:__autoSync(true)

    local relevance = function(self, client)
        local ret = {}
        for k, v in pairs(self) do
            if (type(v) == 'table' or state.isState(v)) and v[client] then
                ret[k] = true
            elseif type(v) == 'boolean' then
                ret[k] = true
            end
        end
        return ret
    end

    root:__relevance(relevance)
    root.group1 = {}
    root.group1:__relevance(relevance)
    root.group2 = {}
    root.group2:__relevance(relevance)
    root.group3 = {}
    root.group3:__relevance(relevance)

    local targetA, targetB = {}, {}

    -- Start
    targetA = state.apply(targetA, root:__diff('a', true))
    targetB = state.apply(targetA, root:__diff('b', true))
    root:__flush()
    assert(equal(targetA, {
    }))
    assert(equal(targetB, {
    }))

    -- Make a group relevant
    root.group1.a = true
    targetA = state.apply(targetA, root:__diff('a'))
    targetB = state.apply(targetB, root:__diff('b'))
    root:__flush()
    assert(equal(targetA, {
        group1 = { a = true },
    }))
    assert(equal(targetB, {
    }))

    -- Add stuff in group
    root.group1[1] = { a = true, b = true }
    root.group1[2] = { b = true }
    targetA = state.apply(targetA, root:__diff('a'))
    targetB = state.apply(targetB, root:__diff('b'))
    root:__flush()
    assert(equal(targetA, {
        group1 = {
            a = true,
            [1] = { a = true, b = true },
        },
    }))
    assert(equal(targetB, {
    }))

    -- Make it relevant to other client
    root.group1.b = true
    targetA = state.apply(targetA, root:__diff('a'))
    targetB = state.apply(targetB, root:__diff('b'))
    root:__flush()
    assert(equal(targetA, {
        group1 = {
            a = true, b = true,
            [1] = { a = true, b = true },
        },
    }))
    assert(equal(targetB, {
        group1 = {
            a = true, b = true,
            [1] = { a = true, b = true },
            [2] = { b = true },
        },
    }))

    -- Make it irrelevant to first client
    root.group1.a = nil
    targetA = state.apply(targetA, root:__diff('a'))
    targetB = state.apply(targetB, root:__diff('b'))
    root:__flush()
    assert(equal(targetA, {
    }))
    assert(equal(targetB, {
        group1 = {
            b = true,
            [1] = { a = true, b = true },
            [2] = { b = true },
        },
    }))
end


-- `nil`-out a table with reference
local function testAutoApplyRelevanceNilling()
    local root = state.new()
    root:__autoSync(true)

    local relevance = function(self, client)
        local ret = {}
        for k, v in pairs(self) do
            if (type(v) == 'table' or state.isState(v)) and v[client] then
                ret[k] = true
            elseif type(v) == 'boolean' then
                ret[k] = true
            end
        end
        return ret
    end

    -- We will have relevance that chooses groups at root, and relevance that chooses elements
    -- within groups in at groups.
    root:__relevance(relevance)
    root.group1 = {}
    root.group1:__relevance(relevance)
    root.group2 = {}
    root.group2:__relevance(relevance)
    root.group3 = {}
    root.group3:__relevance(relevance)

    local targetA, targetB = {}, {}

    do -- SETUP
        -- Start
        targetA = state.apply(targetA, root:__diff('a', true))
        targetB = state.apply(targetA, root:__diff('b', true))
        root:__flush()
        assert(equal(targetA, {
        }))
        assert(equal(targetB, {
        }))

        -- Make a group relevant
        root.group1.a = true
        targetA = state.apply(targetA, root:__diff('a'))
        targetB = state.apply(targetB, root:__diff('b'))
        root:__flush()
        assert(equal(targetA, {
            group1 = { a = true },
        }))
        assert(equal(targetB, {
        }))

        -- Add stuff in group
        root.group1[1] = { a = true, b = true }
        root.group1[2] = { b = true }
        targetA = state.apply(targetA, root:__diff('a'))
        targetB = state.apply(targetB, root:__diff('b'))
        root:__flush()
        assert(equal(targetA, {
            group1 = {
                a = true,
                [1] = { a = true, b = true },
            },
        }))
        assert(equal(targetB, {
        }))

        -- Make it relevant to other client
        root.group1.b = true
        targetA = state.apply(targetA, root:__diff('a'))
        targetB = state.apply(targetB, root:__diff('b'))
        root:__flush()
        assert(equal(targetA, {
            group1 = {
                a = true, b = true,
                [1] = { a = true, b = true },
            },
        }))
        assert(equal(targetB, {
            group1 = {
                a = true, b = true,
                [1] = { a = true, b = true },
                [2] = { b = true },
            },
        }))

        -- Add in other group
        root.group2.b = true
        root.group2[1] = { a = true, b = true }
        targetA = state.apply(targetA, root:__diff('a'))
        targetB = state.apply(targetB, root:__diff('b'))
        root:__flush()
        assert(equal(targetA, {
            group1 = {
                a = true, b = true,
                [1] = { a = true, b = true },
            },
        }))
        assert(equal(targetB, {
            group1 = {
                a = true, b = true,
                [1] = { a = true, b = true },
                [2] = { b = true },
            },
            group2 = {
                b = true,
                [1] = { a = true, b = true },
            }
        }))
    end

    do -- ACTUAL TEST
        -- Make an element with relevance inside `nil`
        root.group1 = nil
        targetA = state.apply(targetA, root:__diff('a'))
        targetB = state.apply(targetB, root:__diff('b'))
        root:__flush()
        assert(equal(targetA, {
        }))
        assert(equal(targetB, {
            group2 = {
                b = true,
                [1] = { a = true, b = true },
            }
        }))
    end
end

testBasic()
testSync()
testAutoSync()
testAutoSyncRelevance()
testAutoApply()
testAutoApplyRelevance()
testAutoApplyRelevanceAtRoot()
testAutoApplyRelevanceNested()
testAutoApplyRelevanceNilling()


print('no errors? then everything passed...')

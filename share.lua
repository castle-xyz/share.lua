local assert = assert
local newproxy = newproxy
local setmetatable, getmetatable = setmetatable, getmetatable
local rawset, rawget = rawset, rawget
local type = type
local tostring = tostring
local next = next


local NILD = 'NILD' -- Sentinel to encode `nil`-ing in diffs -- TODO(nikki): Make this smaller


local Methods = {}

Methods.__isNode = true


-- `proxy` per `node` that stores metadata. This is needed because `node`s are 'userdata'-typed.
--
--    `.name`: name
--    `.children`: `child.name` -> `child` (leaf or node) for all children
--    `.parent`: parent node, `nil` if root
--    `.dirty`: `child.name` -> `true` if that key is dirty
--    `.nilled`: `child.name` -> `true` for keys that got `nil`'d
--    `.dirtyRec`: whether all keys are dirty recursively
--    `.autoSync`: `true` for auto-sync just here, `'rec'` for recursive
local proxies = setmetatable({}, { mode = 'k' })


-- `pairs`, `ipairs` wrappers for nodes

local oldPairs = pairs
function pairs(t)
    local proxy = proxies[t]
    if not proxy then return oldPairs(t) end
    return oldPairs(proxy.children)
end
local pairs = oldPairs

local oldIPairs = ipairs
function ipairs(t)
    local proxy = proxies[t]
    if not proxy then return oldIPairs(t) end
    return oldIPairs(proxy.children)
end
local ipairs = oldIPairs


-- Make a node out of of `t` with given `name`, makes a root node if `parent` is `nil`
local function adopt(parent, name, t)
    local node, proxy

    -- Make it a node
    if proxies[t] then -- Was already a node -- make sure it's orphaned and reuse
        node, proxy = t, proxies[t]
        assert(proxy.parent, 'tried to adopt a root node')
        assert(proxies[proxy.parent].children[proxy.name] ~= t, 'tried to adopt an adopted node')
    else -- New node
        assert(not getmetatable(t), 'tried to adopt a table that has a metatable')
        node = newproxy(true)
        local meta = getmetatable(node)
        proxy = {}
        proxies[node] = proxy

        -- Create the `.children` table as our `__index`, with a final lookup in `Methods`
        local children = setmetatable({}, { __index = Methods })
        proxy.children = children
        meta.__index = children

        -- Copy everything, recursively adopting child tables
        for k, v in pairs(t) do
            if type(v) == 'table' or proxies[v] then
                adopt(node, k, v)
            else
                children[k] = v
            end
        end

        -- Forward `#node`
        function meta.__len()
            return #children
        end

        -- Initialize dirtiness
        proxy.dirty = {}
        proxy.nilled = {}
        proxy.dirtyRec = false
        proxy.autoSync = false

        -- Listen for `node[k] = v` -- keep this code fast
        local nilled = proxy.nilled
        function meta.__newindex(t, k, v)
            if v == nil then nilled[k] = true end -- Record `nil`'ing
            if type(v) ~= 'table' and not proxies[v] then -- Leaf -- just set
                children[k] = v
            elseif children[k] ~= v then -- Potential node -- adopt if not already adopted
                adopt(node, k, v)
            end
        end
    end

    -- Set name and join parent link
    proxy.name = name
    if parent then
        proxy.parent = parent
        local parentProxy = proxies[parent]
        parentProxy.children[name] = node

        if parentProxy.autoSync == 'rec' then
            proxy.dirtyRec = true
            node:__autoSync(true)
        end
    end

    return node
end


-- `'name1:name2:...:nameN'` on path to this node
function Methods:__path()
    local proxy = proxies[self]
    return (proxy.parent and (proxy.parent:__path() .. ':') or '') .. tostring(proxy.name)
end


-- Mark key `k` for sync. If `k` is `nil`, marks everything recursively.
function Methods:__sync(k)
    local proxy = proxies[self]

    -- Skip all this work if already dirty
    if proxy.dirtyRec or proxy.dirty[k] then
        return
    end

    -- Set and recurse on parent -- skipping recursion if we've done it before
    local skipParent = next(proxy.dirty)
    if k == nil then
        proxy.dirtyRec = true
    else
        proxy.dirty[k] = true
    end
    local parent = proxy.parent
    if not skipParent and parent then
        parent:__sync(proxy.name)
    end
end

-- Get the diff of this node and unmark as dirty.
function Methods:__flush(rec)
    local ret = {}
    local proxy = proxies[self]
    local rec = rec or proxy.dirtyRec
    local children, dirty, nilled = proxy.children, proxy.dirty, proxy.nilled

    for k in pairs(rec and children or dirty) do
        local v = children[k]
        if proxies[v] then -- Is a child node?
            ret[k] = v:__flush(rec)
        elseif nilled[k] then -- Was `nil`'d?
            ret[k] = v == nil and NILD or v -- Make sure it wasn't un-`nil`'d
            nilled[k] = nil
        else
            ret[k] = v
        end
        dirty[k] = nil
    end
    for k in pairs(nilled) do
        nilled[k] = nil
    end
    for k in pairs(dirty) do
        dirty[k] = nil
    end
    assert(not next(dirty), 'nothing should be left in `dirty` at end of `:__flush`')

    proxy.dirtyRec = false
    return ret
end

-- Mark node for 'auto-sync' -- automatically marks keys for sync when they are edited. If `rec` is
-- true, all descendant nodes are marked for auto-sync too. Auto-sync can't be unset once set.
function Methods:__autoSync(rec)
    local proxy = proxies[self]

    -- If not already set, set on self
    if not proxy.autoSync then
        local meta = getmetatable(self)
        local children = proxy.children
        local oldNewindex = meta.__newindex
        function meta.__newindex(t, k, v) -- Listen for `node[k] = v` -- keep this code fast
            if children[k] ~= v then -- Make sure it actually changed
                oldNewindex(t, k, v)
                self:__sync(k)
            end
        end
        proxy.autoSync = true
    end

    -- If not already recursive but recursive is desired, recurse
    if proxy.autoSync ~= 'rec' and rec then
        for k, v in pairs(proxy.children) do
            if proxies[v] then
                v:__autoSync(true)
            end
        end
        proxy.autoSync = 'rec'
    end
end


return adopt(nil, 'share', {})

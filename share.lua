serpent = require 'https://raw.githubusercontent.com/pkulchenko/serpent/522a6239f25997b101c585c0daf6a15b7e37fad9/src/serpent.lua'


local assert = assert
local newproxy = newproxy
local setmetatable, getmetatable = setmetatable, getmetatable
local rawset, rawget = rawset, rawget
local type = type
local tostring = tostring


local NILLED = '__NIL' -- Sentinel to encode `nil`-ing in diffs -- TODO(nikki): Make this smaller


local Methods = {}

Methods.__isNode = true


-- `proxy` per `node` that stores metadata. This is needed because `node`s are 'userdata'-typed.
--
--    `.name`: name
--    `.children`: `child.name` -> `child` (leaf or node) for all children
--    `.parent`: parent node, `nil` if root
--    `.dirty`: `child.name` -> (`true` or `NILLED`)
--    `.dirtyRec`: whether entire subtree is dirty (recursively)
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

        -- Listen for `node[k] = v` -- keep this code fast
        function meta.__newindex(t, k, v)
            if type(v) ~= 'table' and not proxies[v] then -- Leaf -- just set
                children[k] = v
            elseif children[k] ~= v then -- Potential node -- adopt if not already adopted
                adopt(node, k, v)
            end
        end
        proxy.autoSync = false

        -- Initialize dirtiness
        proxy.dirty = {}
        proxy.dirtyRec = false
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

    if proxy.dirtyRec then
        return
    end
    if proxy.dirty[k] then
        return
    end
    local skipPath = next(proxy.dirty) -- If we've set any `.dirty`s already we can skip path
    if k == nil then
        proxy.dirtyRec = true
    else
        proxy.dirty[k] = true
    end

    -- Set `.dirty`s on path to here
    if not skipPath then
        local curr = proxy
        while curr.parent do
            local name, parentProxy = curr.name, proxies[curr.parent]
            local parentDirty = parentProxy.dirty
            if parentDirty[name] then
                break
            end
            parentDirty[name] = true
            curr = parentProxy
        end
    end
end

-- Get the diff of this node and unmark as dirty.
function Methods:__flush(rec)
    local ret = {}

    local proxy = proxies[self]
    local rec = rec or proxy.dirtyRec

    local children, dirty = proxy.children, proxy.dirty
    for k in pairs(rec and children or dirty) do
        local child = children[k]
        if proxies[child] then
            ret[k] = child:__flush(rec)
        else
            ret[k] = child
        end
        dirty[k] = nil
    end

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

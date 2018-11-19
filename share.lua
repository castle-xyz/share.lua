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
-- Being 'userdata'-typed allows forwarding the `#node` operator and prevents mistaking it for a
-- regular table.
--
--    `.name`: name
--    `.children`: `child.name` -> `child` (leaf or node) for all children
--    `.parent`: parent node, `nil` if root
--    `.dirty`: `child.name` -> `true` if that key is dirty
--    `.nilled`: `child.name` -> `true` for keys that got `nil`'d
--    `.dirtyRec`: whether all keys are dirty recursively
--    `.autoSync`: `true` for auto-sync just here, `'rec'` for recursive
--    `.relevance`: the relevance function if given, `true` if some descendant has one, else `nil`
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

        -- Forward `#node`
        function meta.__len()
            return #children
        end

        -- Initialize dirtiness
        proxy.dirty = {}
        proxy.nilled = {}
        proxy.dirtyRec = false
        proxy.autoSync = false
        proxy.relevance = nil

        -- Listen for `node[k] = v` -- keep this code fast
        local nilled = proxy.nilled
        local function newindex(t, k, v)
            if v == nil then nilled[k] = true end -- Record `nil`'ing
            if type(v) ~= 'table' and not proxies[v] then -- Leaf -- just set
                children[k] = v
            elseif children[k] ~= v then -- Potential node -- adopt if not already adopted
                adopt(node, k, v)
            end
        end
        meta.__newindex = newindex

        -- Copy initial data
        for k, v in pairs(t) do
            newindex(nil, k, v)
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


-- Mark key `k` for sync. If `k` is `nil` and `rec` is `true`, marks everything recursively.
function Methods:__sync(k, rec)
    local proxy = proxies[self]
    local dirty = proxy.dirty

    -- Skip all this work if already dirty
    if proxy.dirtyRec or dirty[k] then
        return
    end

    -- Set and recurse on parent -- skipping parent if `dirty` is non-empty (we'd've done it before)
    local skipParent = next(dirty)
    if k == nil then
        if rec then
            proxy.dirtyRec = true
        end
    else
        dirty[k] = true
    end
    local parent = proxy.parent
    if not skipParent and parent then
        parent:__sync(proxy.name)
    end
end

-- Get the diff of this node since the last flush.
--   `client`: the client to get the diff w.r.t
--   `rec`: whether to get an 'exact' diff of everything
function Methods:__diff(client, rec, alreadyExact)
    local proxy = proxies[self]
    local relevance = proxy.relevance

    local rec = rec or proxy.dirtyRec
    local children, dirty, nilled = proxy.children, proxy.dirty, proxy.nilled

    local ret = {}

    local relevancy
    if relevance and relevance ~= true then -- Relevance function
        assert(not alreadyExact, "found a `:__relevance` node in an `alreadyExact` branch...")
        local lastRelevancy = proxy.lastRelevancies[client]
        relevancy = relevance(self, client)
        proxy.lastRelevancies[client] = relevancy
        for k in pairs(relevancy) do
            if not lastRelevancy or not lastRelevancy[k] then
                ret[k] = children[k]:__diff(client, true, false)
            elseif dirty[k] then
                ret[k] = children[k]:__diff(client, false, false)
            end
        end
        if lastRelevancy then
            for k in pairs(lastRelevancy) do
                if not relevancy[k] then
                    ret[k] = NILD
                end
            end
        end
    else
        if not relevance then
            if not alreadyExact and rec then
                ret.__exact = true
                alreadyExact = true
            end
        end

        for k in pairs(rec and children or dirty) do
            local v = children[k]
            if proxies[v] then -- Is a child node?
                ret[k] = v:__diff(client, rec, alreadyExact)
            elseif nilled[k] then -- Was `nil`'d?
                ret[k] = v == nil and NILD or v -- Make sure it wasn't un-`nil`'d
                nilled[k] = nil
            else
                ret[k] = v
            end
        end
    end
    if not next(ret) then
        ret = nil
    end
    return ret
end

-- Unmark everything recursively. If `getDiff`, returns what the diff was before flushing.
function Methods:__flush(getDiff, client)
    local diff = getDiff and self:__diff(client) or nil
    local proxy = proxies[self]
    local children, dirty = proxy.children, proxy.dirty
    for k in pairs(dirty) do
        local v = children[k]
        if proxies[v] then
            v:__flush()
        end
        dirty[k] = nil
    end
    if next(proxy.nilled) then
        proxy.nilled = {}
    end
    proxy.dirtyRec = false
    return diff
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

function Methods:__relevance(relevance)
    local proxy = proxies[self]
    local prevRelevance = proxy.relevance
    if prevRelevance and not (relevance == true and prevRelevance == true) then
        error('nested nodes with `:__relevance`')
    end
    proxy.relevance = relevance
    if relevance and relevance ~= true then
        proxy.lastRelevancies = setmetatable({}, { __mode = 'k' })
    end
    local parent = proxy.parent
    if parent then
        parent:__relevance(true)
    end
end


local function apply(t, diff)
    if diff == nil then return t end
    if diff.__exact then
        diff.__exact = nil
        return diff
    end
    t = type(t) == 'table' and t or {}
    for k, v in pairs(diff) do
        if type(v) == 'table' then
            t[k] = apply(t[k], v)
        elseif v == NILD then
            t[k] = nil
        else
            t[k] = v
        end
    end
    return t
end


return {
    new = function(name)
        return adopt(nil, name or 'root', {})
    end,

    apply = apply,
}

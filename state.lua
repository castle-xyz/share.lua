local assert = assert
local newproxy = newproxy
local setmetatable, getmetatable = setmetatable, getmetatable
local type = type
local tostring = tostring
local next = next


local DIFF_NIL = '__NIL' -- Sentinel to encode `nil`-ing in diffs -- TODO(nikki): Make this smaller


local function nonempty(t) return next(t) ~= nil end


local Methods = {}

Methods.__isNode = true


-- `proxy` per `node` that stores metadata. This is needed because `node`s are 'userdata'-typed.
-- Being 'userdata'-typed allows forwarding the `#node` operator and prevents mistaking it for a
-- regular table.
--
--    `.name`: name
--    `.children`: `child.name` -> `child` (leaf or node) for all children
--    `.parent`: parent node, `nil` if root
--
--    `.dirty`: `child.name` -> `true` if that key is dirty
--    `.dirtyRec`: whether all keys are dirty recursively
--    `.autoSync`: `true` for auto-sync just here, `'rec'` for recursive
--
--    `.caches`: diff-related caches for this subtree till next flush
--
--    `.relevanceDescs`: `child.name` -> `true` for keys that have a descendant with relevance
--
--  The following are non-`nil` only if this exact node has relevance
--
--    `.relevance`: the relevance function if given, `true` if some descendant has one, else `nil`
--    `.lastRelevancies`: `client` -> `k` -> non-`nil` map for relevancies before flush
--    `.nextRelevancies`: `client` -> `k` -> non-`nil` map for relevancies till next flush
--
local proxies = setmetatable({}, { __mode = 'k' })


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
        proxy.dirtyRec = false
        proxy.autoSync = false
        proxy.relevance = nil
        proxy.lastRelevancies = nil
        proxy.nextRelevancies = nil
        proxy.relevanceDescs = nil
        proxy.caches = nil

        -- Listen for `node[k] = v` -- keep this code fast
        local function newindex(t, k, v)
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
    local skipParent = nonempty(dirty)
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
--   `exact`: whether to get an 'exact' diff of everything
function Methods:__diff(client, exact, alreadyExact, caches)
    local proxy = proxies[self]
    exact = exact or proxy.dirtyRec

    -- Initialize caches for this subtree if not already present
    if not caches then
        caches = proxy.caches
        if not caches then
            caches = { diff = {}, diffRec = {} }
            proxy.caches = caches
        end
    end

    -- Check in caches first
    local ret
    if exact then
        ret = caches.diffRec[self]
    else
        ret = caches.diff[self]
    end
    if not ret then
        ret = {}

        -- Don't cache if we or a descendant has relevance (results change per client)
        local relevance, relevanceDescs = proxy.relevance, proxy.relevanceDescs
        local skipCache = relevance or (relevanceDescs and nonempty(relevanceDescs))
        if not alreadyExact and exact then -- If newly exact, add the `.__exact` marker
            ret.__exact = true
            alreadyExact = true
            if not skipCache then
                caches.diffRec[self] = ret
            end
        elseif not exact and not skipCache then
            caches.diff[self] = ret
        end

        local children, dirty = proxy.children, proxy.dirty
        if relevance then -- Has a relevance function -- check the relevancy
            local lastRelevancy = proxy.lastRelevancies[client]
            local relevancy = relevance(self, client)
            proxy.nextRelevancies[client] = relevancy
            for k in pairs(relevancy) do
                -- Send exact if it was previously irrelevant and just became relevant
                if exact or (not lastRelevancy or not lastRelevancy[k]) then
                    ret[k] = children[k]:__diff(nil, true, exact, caches)
                elseif dirty[k] then
                    ret[k] = children[k]:__diff(nil, false, false, caches)
                end
            end
            if lastRelevancy then -- `nil`-out things that became irrelevant since the last time
                for k in pairs(lastRelevancy) do
                    if not relevancy[k] then
                        ret[k] = DIFF_NIL
                    end
                end
            end
        else -- No relevance function -- if `exact` go through all children, else just `dirty` ones
            for k in pairs(exact and children or dirty) do
                local v = children[k]
                if proxies[v] then -- Is a child node?
                    ret[k] = v:__diff(client, exact, alreadyExact, caches)
                elseif v == nil then
                    ret[k] = DIFF_NIL
                else
                    ret[k] = v
                end
            end
        end
    end

    return (exact or nonempty(ret)) and ret or nil -- `{}` in non-exact means nothing changed
end

-- Unmark everything recursively. If `getDiff`, returns what the diff was before flushing.
function Methods:__flush(getDiff, client)
    local diff = getDiff and self:__diff(client) or nil
    local proxy = proxies[self]
    local children, dirty, relevanceDescs = proxy.children, proxy.dirty, proxy.relevanceDescs
    if relevanceDescs then -- Always descend into relevance paths
        for k in pairs(relevanceDescs) do
            children[k]:__flush()
            dirty[k] = nil -- No need to visit again
        end
    end
    for k in pairs(dirty) do -- Flush everything that's dirty
        local v = children[k]
        if proxies[v] then
            v:__flush()
        end
        dirty[k] = nil
    end
    proxy.dirtyRec = false

    -- Reset caches
    proxy.caches = nil

    -- Transer relevancy info to `.lastRelevancies`
    local nextRelevancies = proxy.nextRelevancies
    if nextRelevancies then
        local lastRelevancies = proxy.lastRelevancies
        for client in pairs(nextRelevancies) do
            lastRelevancies[client] = nextRelevancies[client]
            nextRelevancies[client] = nil
        end
    end

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

-- Set the relevance function for a node. The function should take two arguments -- the node itself
-- and the `client` passed to `:__diff` or `:__flush`; and return the set of keys of the node
-- relevant to that client (as keys of a table).
function Methods:__relevance(relevance)
    local proxy = proxies[self]

    -- Already had one and just updating? We don't need to do the rest of the work
    if proxy.relevance then
        proxy.relevance = relevance
        return
    end

    -- Have descendants with relevance? That's not good...
    if proxy.relevanceDescs then
        error('nested nodes with `:__relevance`')
    end

    -- Tell ancestors
    local curr = proxy
    while curr.parent do
        local parent = proxies[curr.parent]
        assert(not parent.relevance, 'nested nodes with `:__relevance`')
        local relevanceDescs = parent.relevanceDescs
        if not relevanceDescs then
            relevanceDescs = {}
            parent.relevanceDescs = relevanceDescs
        end
        relevanceDescs[curr.name] = true
        curr = parent
    end

    -- Set up relevance data for this node
    proxy.relevance = relevance
    proxy.lastRelevancies = setmetatable({}, { __mode = 'k' })
    proxy.nextRelevancies = setmetatable({}, { __mode = 'k' })
end


-- Apply a diff from `:__diff` or `:__flush` to a target `t`
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
        elseif v == DIFF_NIL then
            t[k] = nil
        else
            t[k] = v
        end
    end
    return t
end


return {
    new = function(t, name)
        return adopt(nil, name or 'root', t or {})
    end,

    apply = apply,

    DIFF_NIL = DIFF_NIL,
}

local assert = assert
local newproxy = newproxy
local setmetatable, getmetatable = setmetatable, getmetatable
local type = type
local tostring = tostring
local next = next


local DIFF_NIL = '__NIL' -- Sentinel to encode `nil`-ing in diffs -- TODO(nikki): Make this smaller


local function nonempty(t) return next(t) ~= nil end


local function serializable(v) return type(v) ~= 'userdata' end


local Methods = {}


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


-- `pairs`, `ipairs` wrappers for nodes -- also set in `portal.globals` for ghost / castle engine

local oldPairs = pairs
function pairs(t)
    local proxy = proxies[t]
    if not proxy then return oldPairs(t) end
    return oldPairs(proxy.children)
end
if portal then portal.globals.pairs = pairs end
local pairs = oldPairs

local oldIPairs = ipairs
function ipairs(t)
    local proxy = proxies[t]
    if not proxy then return oldIPairs(t) end
    return oldIPairs(proxy.children)
end
if portal then portal.globals.ipairs = ipairs end
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
            local vProxy = proxies[v]
            if type(v) ~= 'table' and not vProxy then -- Leaf -- just set
                children[k] = v
            elseif children[k] ~= v then -- If it's reference-equal we don't need to do anything...
                local child = children[k]
                local childProxy = proxies[child]
                if not childProxy then -- Not previously a node here, just make a new one
                    adopt(node, k, v)
                else -- There's already a node here, let's see if we should edit vs. overwrite
                    local childChildren = childProxy.children
                    local vChildren = vProxy and vProxy.children or v
                    local nSame, nNew, nRemove = 0, 0, 0
                    for kp in pairs(vChildren) do
                        if childChildren[kp] then
                            nSame = nSame + 1
                        else
                            nNew = nNew + 1
                        end
                    end
                    for kp in pairs(childChildren) do
                        if not vChildren[kp] then
                            nRemove = nRemove + 1
                        end
                    end
                    if nSame < nNew + 0.5 * nRemove then -- Not worth it, just overwrite
                        adopt(node, k, v)
                    else -- Editing could be worth it
                        for kp, vp in pairs(vChildren) do
                            child[kp] = vp
                        end
                        for kp in pairs(childChildren) do
                            if not vChildren[kp] then
                                child[kp] = nil
                            end
                        end
                    end
                end
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
            node:__sync(nil, true) -- We were newly added
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

-- This node as a table -- be careful about editing the table (normal events won't fire)
function Methods:__table()
    return proxies[self].children
end

-- Mark key `k` for sync. If `k` is `nil` and `rec` is `true`, marks everything recursively.
function Methods:__sync(k, rec)
    local start = proxies[self]

    do -- Abort if any ancestor has `.dirtyRec` since that means we're all dirty anyways
        local proxy = start
        while true do
            if proxy.dirtyRec then return end
            local parent = proxy.parent
            if not parent then break end
            proxy = proxies[parent]
        end
    end

    local proxy = start
    while true do
        local dirty = proxy.dirty
        local somePrevDirty -- If some other key was dirty -- commonly hit if many edits to a table
        if k == nil then
            if rec then
                proxy.dirtyRec = true
            end
            somePrevDirty = nonempty(dirty)
        else
            if dirty[k] then return end -- We can skip the `next` call in this case
            somePrevDirty = nonempty(dirty)
            dirty[k] = true
        end
        if somePrevDirty then return end -- We can skip parent -- we'd've done it for the other key

        local parent = proxy.parent -- Proceed to mark self as dirty in parent
        if not parent then return end
        k = proxy.name
        proxy = proxies[parent]
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
        if relevance then -- Has a relevance function -- only go through children in relevancy
            -- In the below we make sure not to put `DIFF_NIL`s in an exact diff
            local lastRelevancy = proxy.lastRelevancies[client]
            local relevancy = relevance(self, client)
            proxy.nextRelevancies[client] = relevancy
            for k in pairs(relevancy) do
                -- Send exact if it was previously irrelevant and just became relevant
                local exactHere = exact or (not lastRelevancy or not lastRelevancy[k])
                if exactHere or dirty[k] then
                    local v = children[k]
                    if proxies[v] then
                        ret[k] = v:__diff(client, exactHere, alreadyExact, caches)
                    elseif v == nil then
                        if not exact then
                            ret[k] = DIFF_NIL
                        end
                    elseif serializable(v) then
                        ret[k] = v
                    end
                end
            end
            if not exact then
                if lastRelevancy then -- `nil`-out things that became irrelevant since the last time
                    for k in pairs(lastRelevancy) do
                        if not relevancy[k] then
                            ret[k] = DIFF_NIL
                        end
                    end
                end
            end
        else -- No relevance function -- if `exact` go through all children, else just `dirty` ones
            for k in pairs(exact and children or dirty) do
                local v = children[k]
                if proxies[v] then -- Is a child node?
                    ret[k] = v:__diff(client, exact, alreadyExact, caches)
                elseif v == nil then -- This can only happen if `not exact`
                    ret[k] = DIFF_NIL
                elseif serializable(v) then
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
            local v = children[k]
            if v ~= nil and proxies[v] then
                v:__flush()
            else -- It's not a child anymore -- remove from `relevanceDescs`
                relevanceDescs[k] = nil
            end
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
        end
        for client in pairs(lastRelevancies) do
            if not nextRelevancies[client] then
                lastRelevancies[client] = nil
            end
        end
        for client in pairs(nextRelevancies) do
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

    -- Tell ancestors
    local curr = proxy
    while curr.parent do
        local parent = proxies[curr.parent]
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

    isState = function(t) return proxies[t] ~= nil end,
    getProxy = function(t) return proxies[t] end,

    DIFF_NIL = DIFF_NIL,
}

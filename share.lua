serpent = require 'https://raw.githubusercontent.com/pkulchenko/serpent/522a6239f25997b101c585c0daf6a15b7e37fad9/src/serpent.lua'


local assert = assert
local newproxy = newproxy
local setmetatable, getmetatable = setmetatable, getmetatable
local rawset, rawget, pairs = rawset, rawget, pairs
local type = type
local tostring = tostring


local Methods = {}

Methods.__isNode = true


local newIndex

local proxies = setmetatable({}, { mode = 'k' })

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
        local grandchildren = setmetatable({}, { __index = Methods })
        proxy.children = grandchildren
        meta.__index = grandchildren

        -- Copy everything, recursively adopting child tables
        for k, v in pairs(t) do
            if type(v) == 'table' or proxies[v] then
                adopt(node, k, v)
            else
                grandchildren[k] = v
            end
        end

        -- Forward `#node`
        function meta.__len()
            return #grandchildren
        end

        -- Forward `pairs(node)` -- TODO(nikki): This needs -DLUAJIT_ENABLE_LUA52COMPAT
        function meta.__pairs()
            return pairs(grandchildren)
        end

        -- Listen for `node[k] = v`
        function meta.__newindex(t, k, v)
            print(node:__path(), '<-', k, '<-', tostring(v))

            if type(v) ~= 'table' and not proxies[v] then -- Leaf -- keep this code path fast
                grandchildren[k] = v
            else -- Potential node -- adopt
                adopt(node, k, v)
            end
        end

        -- Initialize other fields
        proxy.dirty = {}
    end

    -- Set name and join parent link
    proxy.name = name
    if parent then
        proxy.parent = parent
        proxies[parent].children[name] = node
    end

    -- Newly adopted -- need to sync everything
    proxy.allDirty = true

    return node
end


function Methods:__path()
    local proxy = proxies[self]
    return (proxy.parent and (proxy.parent:__path() .. ':') or '') .. tostring(proxy.name)
end


function Methods:__sync(k)
    local proxy = proxies[self]

    if proxy.allDirty then
        return
    end
    local skipPath = next(proxy.dirty) -- If we've set any `.dirty`s already we can skip path

    -- Set `.dirty` in self
    if k == nil then
        proxy.allDirty = true
    else
        proxy.dirty[k] = true
    end

    -- Set `.dirty`s on path to here
    if not skipPath then
        local curr = proxy
        while curr.parent do
            local name, parent = curr.name, proxies[curr.parent]
            local parentDirty = parent.dirty
            if parentDirty[name] then
                break
            end
            parentDirty[name] = true
            curr = parent
        end
    end
end

function Methods:__flush()
    local proxy = proxies[self]
    local ret = {}
    local children, dirty = proxy.children, proxy.dirty
    for k in pairs(proxy.allDirty and children or dirty) do
        local child = children[k]
        if proxies[child] then
            ret[k] = child:__flush()
        else
            ret[k] = child
        end
        dirty[k] = nil
    end
    proxy.allDirty = false
    return ret
end


return adopt(nil, 'share', {})

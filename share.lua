serpent = require 'https://raw.githubusercontent.com/pkulchenko/serpent/522a6239f25997b101c585c0daf6a15b7e37fad9/src/serpent.lua'


local assert = assert
local setmetatable, getmetatable = setmetatable, getmetatable
local rawset, rawget, pairs = rawset, rawget, pairs
local type = type
local tostring = tostring


local Methods = {}

Methods.__isNode = true


local newIndex

local function adopt(parent, name, t)
    local node

    -- Make it a node
    if t.__isNode then -- Was already a node -- make sure it's orphaned and reuse
        assert(t.__parent, 'tried to adopt a root node')
        assert(t.__parent.__children[t.__name] ~= t, 'tried to adopt an adopted node')
        node = t
    else -- New node
        assert(not getmetatable(t), 'tried to adopt a table that has a metatable')
        node = {}
        local meta = {}

        -- Create the `.__children` table as our `__index`, with a final lookup in `Methods`
        local grandchildren = setmetatable({}, { __index = Methods })
        node.__children = grandchildren
        meta.__index = grandchildren

        -- Copy everything, recursively adopting child tables
        for k, v in pairs(t) do
            if type(v) == 'table' then
                adopt(node, k, v)
            else
                grandchildren[k] = v
            end
        end

        -- Forward `#node` -- TODO(nikki): This needs -DLUAJIT_ENABLE_LUA52COMPAT
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

            if type(v) ~= 'table' then -- Leaf -- just set as child -- keep this code path fast
                grandchildren[k] = v
            else -- Table -- adopt it
                adopt(node, k, v)
            end
        end

        -- Initialize other fields
        node.__dirty = {}

        -- Finally actually set the metatable
        setmetatable(node, meta)
    end

    -- Set name and join parent link
    rawset(node, '__name', name)
    if parent then
        rawset(node, '__parent', parent)
        parent.__children[name] = node
    end

    -- Newly adopted -- need to sync everything
    rawset(node, '__allDirty', true)

    return node
end


function Methods:__path()
    return (self.__parent and (self.__parent:__path() .. ':') or '') .. tostring(self.__name)
end


function Methods:__sync(k)
    if self.__allDirty then
        return
    end
    local skipPath = next(self.__dirty) -- If we've set any `.__dirty`s already we can skip path

    -- Set `.__dirty` in self
    if k == nil then
        self.__allDirty = true
    else
        self.__dirty[k] = true
    end

    -- Set `.__dirty`s on path to here
    if not skipPath then
        local node = self
        while node.__parent do
            local name, parent = node.__name, node.__parent
            local parentDirty = parent.__dirty
            if parentDirty[name] then
                break
            end
            parentDirty[name] = true
            node = parent
        end
    end
end

function Methods:__flush()
    local ret = {}
    local children, dirty = self.__children, self.__dirty
    for k in pairs(self.__allDirty and children or dirty) do
        local child = children[k]
        if type(child) == 'table' then
            ret[k] = child:__flush()
        else
            ret[k] = child
        end
        dirty[k] = nil
    end
    self.__allDirty = false
    return ret
end


return adopt(nil, 'share', {})

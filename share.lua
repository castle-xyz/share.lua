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
        node.__allDirty = false

        -- Finally actually set the metatable
        setmetatable(node, meta)
    end

    -- Set name and join parent link
    rawset(node, '__name', name)
    if parent then
        rawset(node, '__parent', parent)
        parent.__children[name] = node
    end

    return node
end


function Methods:__path()
    return (self.__parent and (self.__parent:__path() .. ':') or '') .. tostring(self.__name)
end


function Methods:__sync(k)
    -- Set `.__dirty` in self
    if k == nil then
        self.__allDirty = true
    else
        self.__dirty[k] = true
    end

    -- Set `.__dirty`s on path to here
    local node = self
    while node.__parent do
        node.__parent.__dirty[node.__name] = true
        node = node.__parent
    end
end

function Methods:__flush()
    local ret = {}
end


return adopt(nil, 'share', {})

local assert = assert
local setmetatable, getmetatable = setmetatable, getmetatable


local Methods = {}

Methods.__isNode = true


local newIndex

local function adopt(parent, name, child)
    local newChild

    -- Make it a node
    if child.__isNode then -- Was already a node -- make sure it's orphaned and reuse
        assert(child.__parent, 'tried to adopt a root node')
        assert(child.__parent.__children[child.__name] ~= child, 'tried to adopt an adopted node')
        newChild = child
    else -- New node
        newChild = {}

        -- Create the `.__children` table as our `__index`, with a final lookup in `Methods`
        local grandchildren = setmetatable({}, { __index = Methods })
        newChild.__children = grandchildren
        setmetatable(newChild, { __index = grandchildren, __newindex = newIndex })

        -- Copy everything, recursively adopting child tables
        for k, v in pairs(child) do
            if type(v) == 'table' then
                adopt(newChild, k, v)
            else
                grandchildren[k] = v
            end
        end
    end

    -- Set name and join parent link
    rawset(newChild, '__name', name)
    if parent then
        rawset(newChild, '__parent', parent)
        parent.__children[name] = newChild
    end

    return newChild
end

function newIndex(node, k, v)
    print(node:__path(), '<-', k, '<-', tostring(v))

    if type(v) ~= 'table' then -- Leaf -- just set as child -- keep this code path fast
        node.__children[k] = v
    else -- Table -- adopt it
        adopt(node, k, v)
    end
end


function Methods:__path()
    return (self.__parent and (self.__parent:__path() .. ':') or '') .. tostring(self.__name)
end


return adopt(nil, 'share', {})

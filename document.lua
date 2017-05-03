#!/usr/bin/env tarantool

local math = require("math")
local ffi = require 'ffi'
local builtin = ffi.C

local MAX_REMOTE_CONNS_TO_CACHE = 100

local local_schema_cache = {}
local remote_schema_cache = {}

local local_schema_id = nil
local remote_schema_id = {}

local function is_array(table)
    local max = 0
    local count = 0
    for k, v in pairs(table) do
        if type(k) == "number" then
            if k > max then max = k end
            count = count + 1
        else
            return false
        end
    end
    if max > count * 2 then
        return false
    end

    return true
end

local function split(inputstr, sep)
        if sep == nil then
                sep = "%s"
        end
        local t={} ; i=1
        for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
                t[i] = str
                i = i + 1
        end
        return t
end

local function get_tarantool_type(value)
    local type_name = type(value)
    if type_name == "string" then
        return "string"
    elseif type_name == "number" then
        return "scalar"
    elseif type_name == "boolean" then
        return "scalar"
    elseif type_name == "table" then
        if is_array(value) then
            return "array"
        else
            return "map"
        end
    end

    return nil
end

local function split(inputstr, sep)
        if sep == nil then
                sep = "%s"
        end
        local t={}
        local i=1
        for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
                t[i] = str
                i = i + 1
        end
        return t
end

local function shallowcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in pairs(orig) do
            copy[orig_key] = orig_value
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

local function flatten_schema(schema)
    local function flatten_schema_rec(res, path, schema)
        for k, v in pairs(schema) do
            local subpath = nil
            if path == nil then
                subpath = k
            else
                subpath = path .. "." .. k
            end

            if v[1] == nil then
                flatten_schema_rec(res, subpath, v)
            else
                res[v[1]] = {[subpath] = v[2] }
            end
        end
    end

    local res = {}

    if schema ~= nil then
        flatten_schema_rec(res, nil, schema)
    end

    return res
end

local function unflatten_schema(schema)
    local root = {}

    for i, v in ipairs(schema) do
        for k, type_name in pairs(v) do
            local parts = split(k, '.')
            local node = root
            for part_no = 1,#parts-1 do
                local part = parts[part_no]
                if node[part] == nil then
                    node[part] = {}
                end
                node = node[part]
            end

            node[parts[#parts]] = {i, type_name}
        end
    end


    return root
end

local function get_schema(space)
    if space.remote == nil then
        if local_schema_id ~= builtin.sc_version then
            local_schema_cache = {}
            local_schema_id = builtin.sc_version
        end

        local cached = local_schema_cache[space.id]

        if cached == nil then
            local flat = space:format()
            cached = unflatten_schema(flat)
            local_schema_cache[space.id] = cached
        end

        return cached
    else
        local remote = space:remote()

        local conn_id = remote._connection_id
        local conn = remote_schema_cache[conn_id]

        if not conn then
            if #remote_schema_cache > MAX_REMOTE_CONNS_TO_CACHE then
                remote_schema_cache = {}
                remote_schema_id = {}
            end

            conn = {}
            remote_schema_cache[conn_id] = conn
        end

        local schema_id = remote_schema_id[conn_id]

        if schema_id ~= remote._schema_id then
            conn = {}
            remote_schema_cache[conn_id] = conn
        end

        local cached = conn[space.id]

        if cached == nil then
            -- There's a bug in net.box when space objects are not
            -- updated on schema change. We then have to re-request
            -- the object from net.box
            local flat = remote.space[space.id]:format()
            cached = unflatten_schema(flat)
            conn[space.id] = cached
        end

        return cached
    end
end

local function set_schema(space, schema, old_schema)
    schema = flatten_schema(schema)
    old_schema = flatten_schema(old_schema)

    if space.remote == nil then
        space:format(schema)
    else

        local remote = space:remote()
        local result = remote:call('_document_remote_set_schema', space.id, schema, old_schema)
        if result ~= nil then
            remote:reload_schema()
        end

        return result
    end
end

function _document_remote_set_schema(space_id, schema, old_schema)
    if box.session.user() ~= 'admin' then
        return box.session.su('admin', _document_remote_set_schema,
                              space_id, schema, old_schema)
    end

    local local_schema = box.space[space_id]:format()

    if #local_schema ~= #old_schema then
        return nil
    end

    -- Compare local and the previous version of remote schema
    for i, v in pairs(local_schema) do
        local lhs = v
        local rhs = old_schema[i]

        for lhs_key, lhs_type_name in pairs(lhs) do
            for rhs_key, rhs_type_name in pairs(rhs) do
                if lhs_key ~= rhs_key or lhs_type_name ~= rhs_type_name then
                    return nil
                end
                break
            end
            break
        end
    end

    box.space[space_id]:format(schema)

    return schema
end

local function schema_get_max_index(schema)
    local max_index = 0

    for _, v in pairs(schema or {}) do
        if v[1] == nil then
            max_index = math.max(max_index, schema_get_max_index(v))
        else
            max_index = math.max(max_index, v[1])
        end
    end
    return max_index
end

local function extend_schema(tbl, schema)
    local function extend_schema_rec(tbl, schema, max_index)
        schema = shallowcopy(schema)
        for k, v in pairs(tbl) do
            if type(v) == "table" then
                local new_schema = nil
                new_schema, max_index = extend_schema_rec(
                    v, schema[k] or {}, max_index)
                schema[k] = new_schema
            elseif schema[k] == nil then
                max_index = max_index + 1
                schema[k] = {max_index, get_tarantool_type(v)}
            end
        end

        return schema, max_index
    end

    local max_index = schema_get_max_index(schema)
    local _ = nil
    schema, _ = extend_schema_rec(tbl, schema or {}, max_index)
    return schema
end

local function flatten_table(tbl, schema)
    local function flatten_table_rec(res, tbl, schema)
        for k, v in pairs(tbl) do
            local entry = schema[k]
            if entry == nil then
                return nil
            end

            if type(v) == "table" then
                flatten_table_rec(res, v, entry)
            else
                res[entry[1]] = v
            end
        end
        return res
    end

    if tbl == nil then
        return nil
    end

    return flatten_table_rec({}, tbl, schema)
end

local function unflatten_table(tbl, schema)
    local function unflatten_table_rec(tbl, schema)
        local res = {}
        local is_empty = true
        for k, v in pairs(schema) do
            if v[1] == nil then
                local subres = unflatten_table_rec(tbl, v)
                if subres ~= nil then
                    res[k] = subres
                    is_empty = false
                end
            elseif tbl[v[1]] ~= nil then
                res[k] = tbl[v[1]]
                is_empty = false
            end
        end
        if is_empty then
            return nil
        end

        return res
    end

    if tbl == nil then
        return nil
    end

    return unflatten_table_rec(tbl, schema)
end

local function flatten(space_or_schema, tbl)

    if tbl == nil then
        return nil
    end

    if type(tbl) ~= "table" then
        return tbl
    end

    if space_or_schema == nil then
        return nil
    end

    local is_space = true
    local schema = nil

    if getmetatable(space_or_schema) == nil then
        is_space = false
        schema = space_or_schema
    else
        schema = get_schema(space_or_schema)
    end

    local result = flatten_table(tbl, schema)

    if result ~= nil then
        return result
    end

    if not is_space then
        return nil
    end

    local new_schema = nil
    if space_or_schema.remote == nil then
        new_schema = extend_schema(tbl, schema)
        set_schema(space_or_schema, new_schema)
    else

        while true do
            schema = get_schema(space_or_schema)
            new_schema = extend_schema(tbl, schema)
            local result = set_schema(space_or_schema, new_schema, schema)
            if result ~= nil then
                break
            end
        end
    end


    return flatten_table(tbl, new_schema)
end

local function unflatten(space_or_schema, tbl)
    if tbl == nil then
        return nil
    end

    if space_or_schema == nil then
        return nil
    end

    local schema = nil

    if getmetatable(space_or_schema) == nil then
        schema = space_or_schema
    else
        schema = get_schema(space_or_schema)
    end

    return unflatten_table(tbl, schema)
end

local function schema_add_path(schema, path, path_type)
    local path_dict = split(path, ".")

    local root = schema
    for k, v in ipairs(path_dict) do
        if k ~= #path_dict then
            if schema[v] == nil then
                schema[v] = {}
                schema = schema[v]
            else
                schema = schema[v]
            end
        else
            local max_index = schema_get_max_index(root)

            schema[v] = {max_index + 1, path_type}
        end
    end
    return root
end

local function schema_get_field_key(schema, path)
    local path_dict = split(path, ".")

    for k, v in ipairs(path_dict) do
        schema = schema[v]
        if schema == nil then
            return nil
        end
    end


    if type(schema[1]) == "table" then
        return nil
    end

    return schema[1]
end

local function field_key(space, path)
    local schema = get_schema(space)

    return schema_get_field_key(schema, path)
end

local function create_index(space, index_name, orig_options)
    local schema = get_schema(space)

    local options = {}

    if orig_options ~= nil then
        options = shallowcopy(orig_options)
    end

    options.parts = {'id', 'unsigned'}

    if orig_options ~= nil and orig_options.parts ~= nil then
        options.parts = orig_options.parts
    end

    local res = {}
    for k, v in ipairs(options.parts) do
        if k % 2 == 1 then
            if type(v) == "string" then
                local field_key = schema_get_field_key(schema, v)
                if field_key == nil then
                    schema = schema_add_path(schema, v, options.parts[k+1])
                    set_schema(space, schema)
                    field_key = schema_get_field_key(schema, v)
                end
                table.insert(res, field_key)
            else
                table.insert(res, v)
            end
        else
            table.insert(res, v)
        end
    end
    options.parts = res

    space:create_index(index_name, options)

end

return {flatten = flatten,
        unflatten = unflatten,
        create_index = create_index,
        field_key = field_key,
        get_schema = get_schema,
        set_schema = set_schema,
        extend_schema = extend_schema}
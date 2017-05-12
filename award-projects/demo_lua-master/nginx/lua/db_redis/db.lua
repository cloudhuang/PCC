module(..., package.seeall)
local redis = require "lua.db_redis.db_base"
local common = require "lua.comm.common"
local red = redis:new()


function like(oid, uid)
    local ngx_dict_name = "cache_ngx"
    -- get from cache
    local cache_ngx = ngx.shared[ngx_dict_name]
    local is_liked = cache_ngx:get("is_like_"..oid.."_"..uid)
    if is_liked then
        local err = "object already been liked"
        return nil, err
    end
    
    local res, err = red:zadd('like:oid', ngx.time(), uid)
    if err then
        ngx.log(ngx.INFO, "like zadd err:"..err)
        return nil, err
    end

    if res == 0 then
        err = "object already been liked"
        return nil, err
    end
    
    local _get_range_for_like = function(oid)
        local uids, err = red:zrange('like:'..oid, -20, -1)
        return uids
    end

    local uids = common.get_data_with_cache({
                key="range_for_like:"..oid,
                exp_time_succ=600,
                exp_time_fail=-1},
                _get_range_for_like, oid)

    local like_list = {}
    if uids and type(uids) == 'table' then
        for _, uid in pairs(uids) do
            local _get_nickname = function(uid)
                local nickname, err = red:hget('user', uid)
                return nickname
            end

            local nickname = common.get_data_with_cache({
                key="nickname_of_"..uid,
                exp_time_succ=6000,
                exp_time_fail=-1},
                _get_nickname, uid)
            
            if nickname ~= nil then
                table.insert(like_list, { [uid] = nickname})
            end
        end
    end
   
    return like_list, err
end


function is_like(oid, uid)
    local _is_like = function(oid, uid)
        local is_like, err = red:zscore('like:'..oid, uid)
        return is_like and 1 or 0, err
    end

    local is_like, err = common.get_data_with_cache({
        key="is_like_"..oid.."_"..uid,
        exp_time_succ=600,
        exp_time_fail=-1},
        _is_like, oid, uid)

    return is_like, err
end

function count(oid)
    local _get_like_count = function(oid)
        local count, err = red:zcard('like:'..oid)
        return count or 0, err
    end

    local count, err = common.get_data_with_cache({
        key="like_count_of_"..oid,
        exp_time_succ=600,
        exp_time_fail=-1},
        _get_like_count, oid)

    return count, err
end

--action=list&cursor=xxx&page_size=xxx&is_friend=1|0
function list(args)
    local like_list = {}
    local next_cursor = -1
    if args.cursor < 0 then
        local res = {
            like_list = {},
            next_cursor = -1,
            oid = tonumber(oid)
        }
        return res, nil
    end

    local oid = args.oid
    local uid = args.uid
    local cursor = args.cursor
    local page_size = args.page_size
    local is_friend = args.is_friend

    local target_list, size, err
    -- 只返回好友的uid
    if args.is_friend == 1 then
        target_list = "friend_like_list:"..uid
        -- todo: 这里需要优化
        size, err = red:zinterstore(target_list, 2, "like:"..oid, "friend:"..uid)
        size = size or 0
    else
        target_list = "like:"..oid
        local _get_like_size = function(oid)
            local target_list = "like:"..oid
            local s, err = red:zcard(target_list)
            return s or 0
        end
        size, err = common.get_data_with_cache({
          key="like_count_of"..oid,
          exp_time_succ=600,
          exp_time_fail=-1},
          _get_like_size, oid)
    end

    local start, stop
    if cursor == 0 then
        stop = -1
        start = size - page_size
    else
        stop = cursor
        start = stop - page_size
    end
     
    if stop > size then
        stop = size
    end
    if start < 0 then
        start = 0
    end
    next_cursor = start - 1
    
    local uids, err = red:zrange(target_list, start, stop) 
    if uids ~= nil and type(uids) == 'table' then
        for _, uid in pairs(uids) do
            local _get_nickname = function(uid)
                local nickname, err = red:hget('user', uid)
                return nickname
            end

            local nickname = common.get_data_with_cache({
                key="nickname_of_"..uid,
                exp_time_succ=6000,
                exp_time_fail=-1},
                _get_nickname, uid)

            if nickname ~= nil then
                table.insert(like_list, {[uid] = nickname})
            end
        end
    end

    local res = {
        like_list = like_list,
        next_cursor = next_cursor,
        oid = tonumber(oid)
    }
    return res, err
end

-- to prevent use of casual module global variables
getmetatable(lua.db_redis.db).__newindex = function (table, key, val)
    error('attempt to write to undeclared variable "' .. key .. '": '
            .. debug.traceback())
end

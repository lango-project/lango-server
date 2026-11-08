-- Atomic channel generation, trimming, publication and cursor validation.
local stream, meta = KEYS[1], KEYS[2]
local operation, candidate = ARGV[1], ARGV[2]
local retention, maximum = tonumber(ARGV[3]), tonumber(ARGV[4])
local now = redis.call('TIME')
local milliseconds = tonumber(now[1]) * 1000 + math.floor(tonumber(now[2]) / 1000)
local generation = redis.call('HGET', meta, 'generation')
if not generation then
    redis.call('DEL', stream)
    generation = candidate
    redis.call('HSET', meta, 'generation', generation, 'floor', '0-0', 'last', '0-0')
    redis.call('PEXPIRE', meta, retention)
end
local function compare(a, b)
    local am, as = string.match(a, '^(%d+)%-(%d+)$')
    local bm, bs = string.match(b, '^(%d+)%-(%d+)$')
    if #am ~= #bm then return #am < #bm end
    if am ~= bm then return am < bm end
    if #as ~= #bs then return #as < #bs end
    return as < bs
end
local floor = redis.call('HGET', meta, 'floor')
local cutoff = tostring(math.max(0, milliseconds - retention)) .. '-0'
local removed = redis.call('XREVRANGE', stream, '(' .. cutoff, '-', 'COUNT', 1)
if #removed > 0 and compare(floor, removed[1][1]) then floor = removed[1][1] end
redis.call('XTRIM', stream, 'MINID', cutoff)
if operation == 'publish' then
    local id = redis.call('XADD', stream, '*', 'data', ARGV[7])
    redis.call('HSET', meta, 'last', id)
    local excess = redis.call('XLEN', stream) - maximum
    if excess > 0 then
        local old = redis.call('XRANGE', stream, '-', '+', 'COUNT', excess)
        floor = old[#old][1]
        redis.call('XTRIM', stream, 'MAXLEN', maximum)
    end
    redis.call('HSET', meta, 'floor', floor)
    redis.call('PEXPIRE', stream, retention)
    redis.call('PEXPIRE', meta, retention)
    return cjson.encode({generation=generation, id=id})
end
redis.call('HSET', meta, 'floor', floor)
local last = redis.call('HGET', meta, 'last')
if operation == 'cursor' then
    return cjson.encode({generation=generation, id=last})
end
local epoch, position = ARGV[5], ARGV[6]
if epoch ~= '' and (epoch ~= generation or compare(position, floor) or compare(last, position)) then
    return cjson.encode({resyncRequired=true})
end
local entries = redis.call('XRANGE', stream, '(' .. position, '+', 'COUNT', 16)
local messages = {}
local bytes = 0
local id = position
for _, entry in ipairs(entries) do
    local data = entry[2][2]
    if bytes + string.len(data) > 1048576 then break end
    bytes = bytes + string.len(data)
    id = entry[1]
    table.insert(messages, {id=id, data=data})
end
return cjson.encode({generation=generation, id=id, messages=messages})

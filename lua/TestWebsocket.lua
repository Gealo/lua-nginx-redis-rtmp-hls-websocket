
local server = require("resty.websocket.server")
local cjson = require("cjson")
local redis = require("resty.redis")
local red = redis:new()

red:set_timeout(1000)
local ip = "127.0.0.1"
local port = 6379
--如果需要密码就设置一下
--local pwd = 'xxxxx'
local ok , err = red:connect(ip , port)
--red:auth(pwd)
if not ok then
    ngx.say("connect to redis error : " , err)
    return ngx.exit(500)
end

local wb , err = server:new {
    timeout = 5000,
    max_payload_len = 65535
}

--ngx.var.cookie_(cookie name)这里可以获取你想要获取的cookie的名字测试使用flask的所以默认是session，这里就看一下cookie上的那个name就行
local cookie = ngx.var.cookie_session
if cookie == nil then
    ngx.log(ngx.ERR , "no cookie")
    return ngx.exit(403)
end

--这里我redis中session_id是key对应value是用户id
local res , err = red:get(cookie)
if not res then
    ngx.log(ngx.ERR , "get from redis error : " , err)
    return ngx.exit(500)
end
if res == ngx.null then
    ngx.log(ngx.ERR , "oh my god no such key.")
    return ngx.exit(403)
end

if not wb then
    ngx.log(ngx.ERR , "failed to new wesocket: " , err)
    return ngx.exit(444)
end

local len = 0
local key = res
local room = ngx.var.uri
local get_len , err = red:llen(room)
if not get_len then
    get_len = 0
end
local function Send_text(pre_len , now_len , room_num)
    if pre_len < now_len then
        local res , err = red:lrange(room_num , pre_len ,  now_len - 1)
        if res ~= nil then
            for k , v in pairs(res) do
                local bytes , err = wb:send_text(v)
                if not bytes then
                    ngx.say("send failed : " , err)
                end
            end
        end
    end
end
Send_text(len , get_len , room)
len = get_len

while true do
    local get_len , err = red:llen(room_num)
    if not get_len then
        get_len = 0
    end
    Send_text(len , get_len , room_num)
    len = get_len
    local data , typ , err = wb:recv_frame()
    if not data then
        local bytes , err = wb:send_ping()
        if not bytes then
            ngx.say(ngx.ERR , "failed to send ping: " , err)
            return ngx.exit(444)
        end

    elseif typ == "close" then break

    elseif typ == "ping" then
        local bytes , err = wb:send_pong()
        if not bytes then
            ngx.log(ngx.ERR , "failed to send frame: " , err)
            return
        end

    elseif typ == "pong" then
        ngx.log(ngx.INFO , "client ponged")


    elseif typ == "text" then

        local res , err = red:rpush(room , cjson.encode({username=key,value=data}))
        if not res then
            ngx.log(ngx.ERR , "set redis failed!" , err)
            return
        end
    end
end

red:close()
wb:send_close()

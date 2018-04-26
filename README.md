# 用nginx和其他服务器搭建直播平台
通过rtmp推流实现基于hls协议的直播，实现推流权限验证，使用websocket协议实现了实时弹幕系统以及发送弹幕用户验证，通过nginx的反向代理实现跨域cookie
的读取，使用videojs实现了.m3u8格式的视频对Chrome等浏览器等支持，使用redis，mysql实现数据处理。

# 安装openresty
最好是编译安装因为还要添加nginx-rtmp-modules
1.安装对应的依赖pcre，ssl
2.在[官网](http://openresty.org/en/)下载对应的openresty安装包
3.tar xzvf openresty-1.13.6.1.tar.gz 解压下载的包
4.cd openresty-1.13.6.1
5.编译这里prefix(安装路径)with-cc-opt，with-ld-opt，add-module地址根据自己的位置填
```
./configure --prefix=/usr/local/Cellar/ngx_openresty/nginx\
             --with-luajit\
             --without-http_redis2_module \
             --with-http_iconv_module \
             --with-cc-opt='-O2 -I/usr/local/include \
             -I/usr/local/Cellar/pcre/8.41/include \
             -I/usr/local/Cellar/openresty-openssl/1.0.2k_1/include' \
             --with-ld-opt='-Wl,-rpath,/usr/local/Cellar/ngx_openresty/luajit/lib \
             -L/usr/local/Cellar/pcre/8.41/lib \
             -L/usr/local/Cellar/openresty-openssl/1.0.2k_1/lib' \
             --add-module=/usr/local/Cellar/nginx-rtmp-module 
```
如果没什么错误
```
  make
  sudo make install
```
# 安装redis和mysql
安装方法网上都有这就不提了。
# rtmp配置
```
rtmp {

    log_format Rtmp_Log_Fromat '$remote_addr [$time_local] $command "$app" "$name" "$args" -
$bytes_received $bytes_sent "$pageurl" "$flashver" ($session_readable_time)';

    server {
        listen 1935;
        chunk_size 4000;
        access_log logs/rtmp_access.log Rtmp_Log_Fromat;

        application hls {
            live on;
            #on_publish用来实现推流权限验证具体实现在上下文http中
            on_publish http://127.0.0.1:80/on_publish;
            hls on;
            #这里我的路径是html下创建一个hls用来存.m3u8以及.ts。注意这里hls要先创建出来
            hls_path path/to/hls;
            hls_fragment 5s;
        }
    }
}
```
location中的on_publish这里用mysql对用户密钥进行了验证注意sql注入
```
location /on_publish {
            #用于推流验证确保用户使用代理服务器发送的密钥
            default_type text/html;
            #验证通过数据库就应该防止sql注入这里就用ndk.set_var.set_quote_sql_str()即可
            content_by_lua_block {

                local pwd = nil
                local usr = nil
                ngx.req.read_body()
                local arg = ngx.req.get_post_args()
                for k , v in pairs(arg) do
                    if k == 'pass' then
                        pwd = tostring(v)
                    end
                    if k == 'username' then
                        usr = tostring(v)
                    end
                end
                if pwd == nil or usr == nil then
                    return ngx.exit(403)
                end
                local mysql = require("resty.mysql")
                local db , err = mysql:new()
                if not db then
                    ngx.log(ngx.ERR , "failed to instantiate mysql: " , err)
                    return ngx.exit(500)
                end

                db:set_timeout(1000)

                local ok , err , errcode , sqlstate = db:connect {
                    host = "127.0.0.1",
                    port = 3306,
                    database = "database_name",
                    user = "xxxx",
                    password = "xxxxx"
                }
                ngx.log(ngx.ERR , "pwd : " , pwd , "usr : " , usr)
                if not ok then
                    ngx.log(ngx.ERR , "failed to connect: " , err , ": " , errcode , ": " , sqlstate)
                    return ngx.exit(500)
                end
                local res , err , errcode , sqlstate = db:query("select * from user where username = "..ndk.set_var.set_quote_sql_str(usr).."and password = "..ndk.set_var.set_quote_sql_str(pwd))
                --ngx.log(ngx.ERR , "select * from user where username = "..ndk.set_var.set_quote_sql_str(usr).."and password = "..ndk.set_var.set_quote_sql_str(pwd))
                if not res then
                    ngx.log(ngx.ERR , "bad result: " , err , ": " , errcode , ": " , sqlstate)
                    return ngx.exit(500)
                end
                local cjson = require("cjson")
                cjson.encode_empty_table_as_object(false)
                ngx.log(ngx.ERR , cjson.encode(res))
                if cjson.encode(res) == cjson.encode({}) then
                    return ngx.exit(404)
                end
                return ngx.exit(200)
            }
        }
```
# nginx反向代理的配置
由于我其他服务器是使用flask搭建的所以在此反向代理一下，反向代理主要是为了处理跨域session的问题，毕竟通过session确认用户信息状态比较安全而且绝对不
要通过前端来传送这些东西这样太不安全了。
```
location /live/ {
            #反向代理服务器用于解决跨域session的问题，如果要用到获取session的地方只需要在匹配的前缀也加上/live/就是和代理的路径一样即可例如下面的/live/websocket
            default_type text/html;
            #这里填写自己要反向代理的地址
            #proxy_pass http://127.0.0.1:5000;
        }
```
# websocket
如果是要反向代理记得location匹配路径要保持一致比如上面是匹配live代理这里就要live为前缀
```
location /live/websocket {

            lua_socket_log_errors off;
            lua_check_client_abort on;
            content_by_lua_file lua/TestWebsocket.lua;

        }
```
## websocket的lua块
这里我统一了一下flask服务器实现每次登录添加key(session_id):value(user_id),room就是通过uri不加入？后面的args获取,就是http://host/room?{args}
中的room,这里可以用ngx.var.uri来获取。弹幕用redis中的list存储key为room，将内容打包成json格式为{username:user_id,value:data}data就是前端
发送过来的弹幕。
```
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

```
# 一些前端测试页面
测试弹幕
```
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>弹幕测试页面</title>
    <style>
        #text {
            resize : none;
            width : 400px;
            height : 600px;
            box-sizing : border-box;
        }
        #mesage {
            width : 400px;
            box-sizing : border-box;
        }
    </style>
    <script>
        window.onload = function() {
            websocket = new WebSocket("ws://127.0.0.1:80/live/websocket");
            websocket.onopen = function() {

            }
            websocket.onmessage = function (evt) {
                var msg = evt.data;
                console.log(msg);
                document.getElementById("text").innerHTML += msg;
            }
            websocket.onerror = function (evt) {
                console.log(evt);
            }
        }
        function submit() {
            var json = {
                session_id : "",
                user_id : "",
                text : document.getElementById("message").value
            }
            var Val = document.getElementById("message").value
            websocket.send(Val);
        }
    </script>
</head>
<body>
    <textarea id="text"></textarea> <br />
    <input id="message" type="text" placeholder="请输入弹幕" /> <br />
    <input id="submit" type="submit" value="发送" onclick="submit()" /> <br />
</body>
</html>

```
测试直播
```

<!DOCTYPE html>
<html>
<head>
<meta charset=utf-8 />
<title>videojs支持hls在Chrome上播放</title>


  <link href="video-js.css" rel="stylesheet">
  <script src="video.js"></script>
  <script src="videojs-contrib-hls.js"></script>

</head>
<body>

  <video id="my_video_1" class="video-js vjs-default-skin" controls preload="auto" width="640" height="268"
  data-setup='{}'>
    <source src="http://127.0.0.1:80/hls/test.m3u8" type="application/x-mpegURL">
  </video>

  <script>
  </script>

</body>
</html>

```

# 其他nginx相关配置见conf/nginx.conf
这里一定要配置一下不然会有些东西找不到路径

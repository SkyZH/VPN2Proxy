net = require("net")
udpRelay = require('../lib/udprelay')
fs = require("fs")
path = require("path")
utils = require('../lib/utils')
inet = require('../lib/inet')
os = require("os")
exec = require('child_process').exec

localAddr = []

inetNtoa = (buf) ->
  buf[0] + "." + buf[1] + "." + buf[2] + "." + buf[3]
inetAton = (ipStr) ->
  parts = ipStr.split(".")
  unless parts.length is 4
    null
  else
    buf = new Buffer(4)
    i = 0

    while i < 4
      buf[i] = +parts[i]
      i++
    buf

connections = 0


createServer = (port, timeout)->
  
  udpRelay.createServer(port, timeout)
  
  server = net.createServer((connection) ->
    connections += 1
    stage = 0
    headerLength = 0
    remote = null
    cachedPieces = []
    addrLen = 0
    remoteAddr = null
    remotePort = null
    
    utils.debug "connections: #{connections}"
    clean = ->
      utils.debug "clean"
      connections -= 1
      remote = null
      connection = null
      utils.debug "connections: #{connections}"

    connection.on "data", (data) ->
      utils.log utils.EVERYTHING, "connection on data"
      if stage is 10
        utils.error "stage cannot be 10"
      if stage is 5
        # pipe sockets
        connection.pause()  unless remote.write(data)
        return
      if stage is 0
        tempBuf = new Buffer(2)
        tempBuf.write "\u0005\u0000", 0
        console.log data
        connection.write tempBuf
        stage = 1
        utils.debug "stage = 1"
        return
      if stage is 1
        try
          # +----+-----+-------+------+----------+----------+
          # |VER | CMD |  RSV  | ATYP | DST.ADDR | DST.PORT |
          # +----+-----+-------+------+----------+----------+
          # | 1  |  1  | X'00' |  1   | Variable |    2     |
          # +----+-----+-------+------+----------+----------+
  
          #cmd and addrtype
          cmd = data[1]
          addrtype = data[3]
          if cmd is 1
            # TCP

          else if cmd is 3
            # UDP
            utils.info "UDP assc request from #{connection.localAddress}:#{connection.localPort}"
            reply = new Buffer(10)
            reply.write "\u0005\u0000\u0000\u0001", 0, 4, "binary"
            utils.debug connection.localAddress
            inetAton(connection.localAddress).copy reply, 4
            reply.writeUInt16BE connection.localPort, 8
            connection.write reply
            stage = 10
          else
            utils.error "unsupported cmd: " + cmd
            reply = new Buffer("\u0005\u0007\u0000\u0001", "binary")
            connection.end reply
            return
          if addrtype is 3
            addrLen = data[4]
          else unless addrtype in [1, 4]
            utils.error "unsupported addrtype: " + addrtype
            connection.destroy()
            return
          # read address and port
          if addrtype is 1
            remoteAddr = inetNtoa(data.slice(4, 8))
            remotePort = data.readUInt16BE(8)
            headerLength = 10
          else if addrtype is 4
            remoteAddr = inet.inet_ntop(data.slice(4, 20))
            remotePort = data.readUInt16BE(20)
            headerLength = 22
          else
            remoteAddr = data.slice(5, 5 + addrLen).toString("binary")
            remotePort = data.readUInt16BE(5 + addrLen)
            headerLength = 5 + addrLen + 2
          if cmd is 3
            utils.info "UDP assc: #{remoteAddr}:#{remotePort}"
            return
          buf = new Buffer(10)
          buf.write "\u0005\u0000\u0000\u0001", 0, 4, "binary"
          buf.write "\u0000\u0000\u0000\u0000", 4, 4, "binary"
          # 2222 can be any number between 1 and 65535
          buf.writeInt16BE 2222, 8
          connection.write buf
          # connect remote server
          __localAddr = localAddr[Math.floor(Math.random()*localAddr.length)]
          remote = net.connect({port:remotePort, host:remoteAddr, localAddress:__localAddr, family: "IPv4"}, ->
            utils.info "connecting #{remoteAddr}:#{remotePort} through #{__localAddr}"
            i = 0
  
            while i < cachedPieces.length
              piece = cachedPieces[i]
              remote.write piece if remote
              i++
            cachedPieces = null # save memory
            stage = 5
            utils.debug "stage = 5"
          )
          remote.on "data", (data) ->
            utils.log utils.EVERYTHING, "remote on data"
            try
              remote.pause()  unless connection.write(data)
            catch e
              utils.error e
              remote.destroy() if remote
              connection.destroy() if connection
  
          remote.on "end", ->
            utils.debug "remote on end"
            connection.end() if connection
  
          remote.on "error", (e)->
            utils.debug "remote on error"
            utils.error "remote #{remoteAddr}:#{remotePort} error: #{e}"

          remote.on "close", (had_error)->
            utils.debug "remote on close:#{had_error}"
            if had_error
              connection.destroy() if connection
            else
              connection.end() if connection
  
          remote.on "drain", ->
            utils.debug "remote on drain"
            connection.resume()
  
          remote.setTimeout timeout, ->
            utils.debug "remote on timeout"
            remote.destroy() if remote
            connection.destroy() if connection
  
          if data.length > headerLength
            buf = new Buffer(data.length - headerLength)
            data.copy buf, 0, headerLength
            cachedPieces.push buf
            buf = null
          stage = 4
          utils.debug "stage = 4"
        catch e
          # may encounter index out of range
          utils.error e
          throw e
          connection.destroy() if connection
          remote.destroy() if remote
      else cachedPieces.push data  if stage is 4
        # remote server not connected
        # cache received buffers
        # make sure no data is lost
  
    connection.on "end", ->
      utils.debug "connection on end"
      remote.end()  if remote
  
    connection.on "error", (e)->
      utils.debug "connection on error"
      utils.error "local error: #{e}"

    connection.on "close", (had_error)->
      utils.debug "connection on close:#{had_error}"
      if had_error
        remote.destroy() if remote
      else
        remote.end() if remote
      clean()
  
    connection.on "drain", ->
      # calling resume() when remote not is connected will crash node.js
      utils.debug "connection on drain"
      remote.resume() if remote and stage is 5
  
    connection.setTimeout timeout, ->
      utils.debug "connection on timeout"
      remote.destroy() if remote
      connection.destroy() if connection
  )
  server.listen port, ->
    utils.info "server listening at port " + port
  
  server.on "error", (e) ->
    if e.code is "EADDRINUSE"
      utils.error "Address in use, aborting"
    else
      utils.error e
    
  return server

exports.createServer = createServer
exports.main = ->  
  tmpInterfaces = os.networkInterfaces()
  
  localAddr = (value[0].address for item,value of tmpInterfaces when item.match('MultiVPN') != null)
  exec "netsh interface ipv4 add address name=\"" + item + "\" gateway=\"127.0.0.1\" gwmetric=20 store=\"active\"" for item,value of tmpInterfaces when item.match('MultiVPN') != null
  console.log(utils.version)
  configFromArgs = utils.parseArgs()
  configPath = 'config.json'
  if configFromArgs.config_file
    configPath = configFromArgs.config_file
  if not fs.existsSync(configPath)
    configPath = path.resolve(__dirname, "config.json")
    if not fs.existsSync(configPath)
      configPath = path.resolve(__dirname, "../../config.json")
      if not fs.existsSync(configPath)
        configPath = null
  if configPath
    utils.info 'loading config from ' + configPath
    configContent = fs.readFileSync(configPath)
    config = JSON.parse(configContent)
  else
    config = {}
  for k, v of configFromArgs
    config[k] = v
  if config.verbose
    utils.config(utils.DEBUG)

  utils.checkConfig config
  
  PORT = config.local_port
  timeout = Math.floor(config.timeout * 1000) or 600000
  s = createServer PORT, timeout
  s.on "error", (e) ->
    process.stdout.on 'drain', ->
      process.exit 1
if require.main is module
  exports.main()

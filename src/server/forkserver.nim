import std/options
import std/os
import std/posix
import std/tables

import chagashi/charset
import config/config
import config/urimethodmap
import io/dynstream
import io/packetreader
import io/packetwriter
import io/poll
import server/buffer
import server/connecterror
import server/loader
import server/loaderiface
import types/url
import types/winattrs
import utils/proctitle
import utils/sandbox
import utils/strwidth
import utils/twtstr

type
  ForkServer* = ref object
    stream: SocketStream
    estream*: PosixStream

  ForkServerContext = object
    stream: SocketStream
    loaderStream: SocketStream
    pollData: PollData

proc loadConfig*(forkserver: ForkServer; config: Config): int =
  forkserver.stream.withPacketWriter w:
    w.swrite(config.display.doubleWidthAmbiguous)
    w.swrite(LoaderConfig(
      urimethodmap: config.external.urimethodmap,
      w3mCGICompat: config.external.w3mCgiCompat,
      cgiDir: seq[string](config.external.cgiDir),
      tmpdir: config.external.tmpdir,
      configdir: config.dir,
      bookmark: config.external.bookmark
    ))
  var process: int
  forkserver.stream.withPacketReader r:
    r.sread(process)
  return process

proc forkBuffer*(forkserver: ForkServer; config: BufferConfig; url: URL;
    attrs: WindowAttributes; ishtml: bool; charsetStack: seq[Charset]):
    tuple[pid: int; cstream: SocketStream] =
  var sv {.noinit.}: array[2, cint]
  if socketpair(AF_UNIX, SOCK_STREAM, IPPROTO_IP, sv) != 0:
    return (-1, nil)
  forkserver.stream.withPacketWriter w:
    w.swrite(config)
    w.swrite(url)
    w.swrite(attrs)
    w.swrite(ishtml)
    w.swrite(charsetStack)
    w.sendFd(sv[1])
  discard close(sv[1])
  var bufferPid: int
  forkserver.stream.withPacketReader r:
    r.sread(bufferPid)
  if bufferPid == -1:
    discard close(sv[0])
    return (-1, nil)
  return (bufferPid, newSocketStream(sv[0]))

proc forkLoader(ctx: var ForkServerContext; config: LoaderConfig;
    loaderStream: SocketStream): (int, SocketStream) =
  # loaderStream is a connection between main process <-> loader, but we
  # also need a connection between fork server <-> loader.
  # The naming here is very confusing, sorry about that.
  var sv {.noinit.}: array[2, cint]
  if socketpair(AF_UNIX, SOCK_STREAM, IPPROTO_IP, sv) != 0:
    loaderStream.sclose()
    return (-1, nil)
  stderr.flushFile()
  let pid = fork()
  if pid == 0:
    # child process
    try:
      ctx.stream.sclose()
      discard close(sv[0])
      let forkStream = newSocketStream(sv[1])
      setProcessTitle("cha loader")
      runFileLoader(config, loaderStream, forkStream)
    except CatchableError as e:
      stderr.write(e.getStackTrace() & "Error: unhandled exception: " & e.msg &
        " [" & $e.name & "]\n")
      quit(1)
    doAssert false
  else:
    discard close(sv[1])
    loaderStream.sclose()
    return (int(pid), newSocketStream(sv[0]))

proc forkBuffer(ctx: var ForkServerContext; r: var PacketReader): int =
  var config: BufferConfig
  var url: URL
  var attrs: WindowAttributes
  var ishtml: bool
  var charsetStack: seq[Charset]
  r.sread(config)
  r.sread(url)
  r.sread(attrs)
  r.sread(ishtml)
  r.sread(charsetStack)
  let fd = r.recvFd()
  stderr.flushFile()
  let pid = fork()
  if pid == 0:
    # child process
    ctx.stream.sclose()
    ctx.loaderStream.sclose()
    setBufferProcessTitle(url)
    let pid = getCurrentProcessId()
    let urandom = newPosixStream("/dev/urandom", O_RDONLY, 0)
    let pstream = newSocketStream(fd)
    var cacheId: int
    var loaderStream: SocketStream
    var istream: SocketStream
    pstream.withPacketReader r:
      r.sread(cacheId)
      loaderStream = newSocketStream(r.recvFd())
      istream = newSocketStream(r.recvFd())
    let loader = newFileLoader(pid, loaderStream)
    gpstream = pstream
    onSignal SIGTERM:
      discard sig
      if gpstream != nil:
        gpstream.sclose()
        gpstream = nil
      exitnow(1)
    signal(SIGPIPE, SIG_DFL)
    enterBufferSandbox()
    try:
      launchBuffer(config, url, attrs, ishtml, charsetStack, loader, pstream,
        istream, urandom, cacheId)
    except CatchableError:
      let e = getCurrentException()
      # taken from system/excpt.nim
      let msg = e.getStackTrace() & "Error: unhandled exception: " & e.msg &
        " [" & $e.name & "]\n"
      stderr.write(msg)
      quit(1)
    doAssert false
  discard close(fd)
  return pid

proc forkCGI(ctx: var ForkServerContext; r: var PacketReader): int =
  let istream = newPosixStream(r.recvFd())
  let ostream = newPosixStream(r.recvFd())
  # hack to detect when the child died
  var hasOstreamOut2: bool
  r.sread(hasOstreamOut2)
  let ostreamOut2 = if hasOstreamOut2: newPosixStream(r.recvFd()) else: nil
  var env: seq[tuple[name, value: string]]
  var dir: string
  var cmd: string
  var basename: string
  r.sread(env)
  r.sread(dir)
  r.sread(cmd)
  r.sread(basename)
  let pid = fork()
  if pid == 0: # child
    ctx.stream.sclose()
    ctx.loaderStream.sclose()
    # we leave stderr open, so it can be seen in the browser console
    istream.moveFd(STDIN_FILENO)
    ostream.moveFd(STDOUT_FILENO)
    # reset SIGCHLD to the default handler. this is useful if the child
    # process expects SIGCHLD to be untouched.
    # (e.g. git dies a horrible death with SIGCHLD as SIG_IGN)
    signal(SIGCHLD, SIG_DFL)
    # let's also reset SIGPIPE, which we ignored on init
    signal(SIGPIPE, SIG_DFL)
    for it in env:
      putEnv(it.name, it.value)
    setCurrentDir(dir)
    discard execl(cstring(cmd), cstring(basename), nil)
    let code = int(ceFailedToExecuteCGIScript)
    stdout.write("Cha-Control: ConnectionError " & $code & " " &
      ($strerror(errno)).deleteChars({'\n', '\r'}))
    exitnow(1)
  else: # parent or error
    istream.sclose()
    ostream.sclose()
    if ostreamOut2 != nil:
      ostreamOut2.sclose()
    return pid

proc runForkServer(controlStream, loaderStream: SocketStream) =
  setProcessTitle("cha forkserver")
  var ctx = ForkServerContext(stream: controlStream)
  signal(SIGCHLD, SIG_IGN)
  signal(SIGPIPE, SIG_IGN)
  ctx.stream.withPacketReader r:
    var config: LoaderConfig
    r.sread(isCJKAmbiguous)
    r.sread(config)
    # for CGI
    putEnv("SERVER_SOFTWARE", "Chawan")
    putEnv("SERVER_PROTOCOL", "HTTP/1.0")
    putEnv("SERVER_NAME", "localhost")
    putEnv("SERVER_PORT", "80")
    putEnv("REMOTE_HOST", "localhost")
    putEnv("REMOTE_ADDR", "127.0.0.1")
    putEnv("GATEWAY_INTERFACE", "CGI/1.1")
    putEnv("CHA_INSECURE_SSL_NO_VERIFY", "0")
    putEnv("CHA_TMP_DIR", config.tmpdir)
    putEnv("CHA_DIR", config.configdir)
    putEnv("CHA_BOOKMARK", config.bookmark)
    # returns a new stream that connects fork server <-> loader and
    # gives away main process <-> loader
    let (pid, loaderStream) = ctx.forkLoader(config, loaderStream)
    ctx.stream.withPacketWriter w:
      w.swrite(pid)
    if pid == -1:
      # Notified main process of failure; our job is done.
      quit(1)
    ctx.loaderStream = loaderStream
  ctx.pollData.register(ctx.stream.fd, POLLIN)
  ctx.pollData.register(ctx.loaderStream.fd, POLLIN)
  var alive = true
  while alive:
    ctx.pollData.poll(-1)
    for event in ctx.pollData.events:
      if (event.revents and POLLIN) != 0:
        try:
          if event.fd == ctx.stream.fd:
            ctx.stream.withPacketReader r:
              let pid = ctx.forkBuffer(r)
              ctx.stream.withPacketWriter w:
                w.swrite(pid)
          elif event.fd == ctx.loaderStream.fd:
            ctx.loaderStream.withPacketReader r:
              let pid = ctx.forkCGI(r)
              ctx.loaderStream.withPacketWriter w:
                w.swrite(pid)
        except EOFError:
          alive = false # EOF
          break
      if (event.revents and POLLERR) != 0 or (event.revents and POLLHUP) != 0:
        alive = false # EOF
        break
  ctx.stream.sclose()
  # Clean up when the main process crashed.
  discard kill(0, cint(SIGTERM))
  quit(0)

proc newForkServer*(loaderSockVec: array[2, cint]): ForkServer =
  var sockVec {.noinit.}: array[2, cint] # stdin in forkserver
  var pipeFdErr {.noinit.}: array[2, cint] # stderr in forkserver
  if socketpair(AF_UNIX, SOCK_STREAM, IPPROTO_IP, sockVec) != 0:
    stderr.writeLine("Failed to open fork server i/o socket")
    quit(1)
  if pipe(pipeFdErr) == -1:
    stderr.writeLine("Failed to open fork server error pipe")
    quit(1)
  let pid = fork()
  if pid == -1:
    stderr.writeLine("Failed to fork fork the server process")
    quit(1)
  elif pid == 0:
    # child process
    discard setsid()
    closeStdin()
    closeStdout()
    newPosixStream(pipeFdErr[1]).moveFd(STDERR_FILENO)
    discard close(pipeFdErr[0]) # close read
    discard close(sockVec[0])
    discard close(loaderSockVec[0])
    let controlStream = newSocketStream(sockVec[1])
    let loaderStream = newSocketStream(loaderSockVec[1])
    runForkServer(controlStream, loaderStream)
    doAssert false
  else:
    discard close(pipeFdErr[1]) # close write
    discard close(sockVec[1])
    discard close(loaderSockVec[1])
    let stream = newSocketStream(sockVec[0])
    stream.setCloseOnExec()
    let estream = newPosixStream(pipeFdErr[0])
    estream.setCloseOnExec()
    estream.setBlocking(false)
    return ForkServer(stream: stream, estream: estream)

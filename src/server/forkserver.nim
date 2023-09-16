import options
import streams
import tables

when defined(posix):
  import posix

import config/config
import display/window
import io/posixstream
import io/serialize
import io/serversocket
import io/urlfilter
import loader/headers
import loader/loader
import server/buffer
import types/buffersource
import types/cookie
import types/url
import utils/twtstr

type
  ForkCommand* = enum
    FORK_BUFFER, FORK_LOADER, REMOVE_CHILD, LOAD_CONFIG

  ForkServer* = ref object
    process*: Pid
    istream*: Stream
    ostream*: Stream
    estream*: PosixStream

  ForkServerContext = object
    istream: Stream
    ostream: Stream
    children: seq[(Pid, Pid)]

proc newFileLoader*(forkserver: ForkServer, defaultHeaders: Headers,
    filter = newURLFilter(default = true), cookiejar: CookieJar = nil,
    proxy: URL = nil, acceptProxy = false): FileLoader =
  forkserver.ostream.swrite(FORK_LOADER)
  var defaultHeaders = defaultHeaders
  let config = LoaderConfig(
    defaultHeaders: defaultHeaders,
    filter: filter,
    cookiejar: cookiejar,
    proxy: proxy,
    acceptProxy: acceptProxy
  )
  forkserver.ostream.swrite(config)
  forkserver.ostream.flush()
  var process: Pid
  forkserver.istream.sread(process)
  return FileLoader(process: process)

proc loadForkServerConfig*(forkserver: ForkServer, config: Config) =
  forkserver.ostream.swrite(LOAD_CONFIG)
  forkserver.ostream.swrite(config.getForkServerConfig())
  forkserver.ostream.flush()

proc removeChild*(forkserver: Forkserver, pid: Pid) =
  forkserver.ostream.swrite(REMOVE_CHILD)
  forkserver.ostream.swrite(pid)
  forkserver.ostream.flush()

proc trapSIGINT() =
  # trap SIGINT, so e.g. an external editor receiving an interrupt in the
  # same process group can't just kill the process
  # Note that the main process normally quits on interrupt (thus terminating
  # all child processes as well).
  setControlCHook(proc() {.noconv.} = discard)

proc forkLoader(ctx: var ForkServerContext, config: LoaderConfig): Pid =
  var pipefd: array[2, cint]
  if pipe(pipefd) == -1:
    raise newException(Defect, "Failed to open pipe.")
  let pid = fork()
  if pid == 0:
    # child process
    trapSIGINT()
    for i in 0 ..< ctx.children.len: ctx.children[i] = (Pid(0), Pid(0))
    ctx.children.setLen(0)
    zeroMem(addr ctx, sizeof(ctx))
    discard close(pipefd[0]) # close read
    try:
      runFileLoader(pipefd[1], config)
    except CatchableError:
      let e = getCurrentException()
      # taken from system/excpt.nim
      let msg = e.getStackTrace() & "Error: unhandled exception: " & e.msg &
        " [" & $e.name & "]\n"
      stderr.write(msg)
      quit(1)
    doAssert false
  let readfd = pipefd[0] # get read
  discard close(pipefd[1]) # close write
  var readf: File
  if not open(readf, FileHandle(readfd), fmRead):
    raise newException(Defect, "Failed to open output handle.")
  let c = readf.readChar()
  assert c == char(0u8)
  close(readf)
  discard close(pipefd[0])
  return pid

proc forkBuffer(ctx: var ForkServerContext): Pid =
  var source: BufferSource
  var config: BufferConfig
  var attrs: WindowAttributes
  var mainproc: Pid
  ctx.istream.sread(source)
  ctx.istream.sread(config)
  ctx.istream.sread(attrs)
  ctx.istream.sread(mainproc)
  let loaderPid = ctx.forkLoader(
    LoaderConfig(
      defaultHeaders: config.headers,
      filter: config.filter,
      cookiejar: config.cookiejar,
      referrerpolicy: config.referrerpolicy,
      #TODO these should be in a separate config I think
      proxy: config.proxy,
    )
  )
  var pipefd: array[2, cint]
  if pipe(pipefd) == -1:
    raise newException(Defect, "Failed to open pipe.")
  let pid = fork()
  if pid == -1:
    raise newException(Defect, "Failed to fork process.")
  if pid == 0:
    # child process
    trapSIGINT()
    for i in 0 ..< ctx.children.len: ctx.children[i] = (Pid(0), Pid(0))
    ctx.children.setLen(0)
    zeroMem(addr ctx, sizeof(ctx))
    discard close(pipefd[0]) # close read
    let ssock = initServerSocket(buffered = false)
    let ps = newPosixStream(pipefd[1])
    ps.write(char(0))
    ps.close()
    discard close(stdin.getFileHandle())
    discard close(stdout.getFileHandle())
    let loader = FileLoader(process: loaderPid)
    try:
      launchBuffer(config, source, attrs, loader, ssock)
    except CatchableError:
      let e = getCurrentException()
      # taken from system/excpt.nim
      let msg = e.getStackTrace() & "Error: unhandled exception: " & e.msg &
        " [" & $e.name & "]\n"
      stderr.write(msg)
      quit(1)
    doAssert false
  discard close(pipefd[1]) # close write
  let ps = newPosixStream(pipefd[0])
  let c = ps.readChar()
  assert c == char(0)
  ps.close()
  ctx.children.add((pid, loaderPid))
  return pid

proc runForkServer() =
  var ctx: ForkServerContext
  ctx.istream = newPosixStream(stdin.getFileHandle())
  ctx.ostream = newPosixStream(stdout.getFileHandle())
  while true:
    try:
      var cmd: ForkCommand
      ctx.istream.sread(cmd)
      case cmd
      of REMOVE_CHILD:
        var pid: Pid
        ctx.istream.sread(pid)
        for i in 0 .. ctx.children.high:
          if ctx.children[i][0] == pid:
            ctx.children.del(i)
            break
      of FORK_BUFFER:
        ctx.ostream.swrite(ctx.forkBuffer())
      of FORK_LOADER:
        var config: LoaderConfig
        ctx.istream.sread(config)
        let pid = ctx.forkLoader(config)
        ctx.ostream.swrite(pid)
        ctx.children.add((pid, Pid(-1)))
      of LOAD_CONFIG:
        var config: ForkServerConfig
        ctx.istream.sread(config)
        set_cjk_ambiguous(config.ambiguous_double)
        SocketDirectory = config.tmpdir
      ctx.ostream.flush()
    except EOFError:
      # EOF
      break
  ctx.istream.close()
  ctx.ostream.close()
  # Clean up when the main process crashed.
  for childpair in ctx.children:
    let a = childpair[0]
    let b = childpair[1]
    discard kill(cint(a), cint(SIGTERM))
    if b != -1:
      discard kill(cint(b), cint(SIGTERM))
  quit(0)

proc newForkServer*(): ForkServer =
  var pipefd_in: array[2, cint] # stdin in forkserver
  var pipefd_out: array[2, cint] # stdout in forkserver
  var pipefd_err: array[2, cint] # stderr in forkserver
  if pipe(pipefd_in) == -1:
    raise newException(Defect, "Failed to open input pipe.")
  if pipe(pipefd_out) == -1:
    raise newException(Defect, "Failed to open output pipe.")
  if pipe(pipefd_err) == -1:
    raise newException(Defect, "Failed to open error pipe.")
  let pid = fork()
  if pid == -1:
    raise newException(Defect, "Failed to fork the fork process.")
  elif pid == 0:
    # child process
    trapSIGINT()
    discard close(pipefd_in[1]) # close write
    discard close(pipefd_out[0]) # close read
    discard close(pipefd_err[0]) # close read
    let readfd = pipefd_in[0]
    let writefd = pipefd_out[1]
    let errfd = pipefd_err[1]
    discard dup2(readfd, stdin.getFileHandle())
    discard dup2(writefd, stdout.getFileHandle())
    discard dup2(errfd, stderr.getFileHandle())
    stderr.flushFile()
    discard close(pipefd_in[0])
    discard close(pipefd_out[1])
    discard close(pipefd_err[1])
    runForkServer()
    doAssert false
  else:
    discard close(pipefd_in[0]) # close read
    discard close(pipefd_out[1]) # close write
    discard close(pipefd_err[1]) # close write
    var writef, readf: File
    if not open(writef, pipefd_in[1], fmWrite):
      raise newException(Defect, "Failed to open output handle")
    if not open(readf, pipefd_out[0], fmRead):
      raise newException(Defect, "Failed to open input handle")
    discard fcntl(pipefd_err[0], F_SETFL, fcntl(pipefd_err[0], F_GETFL, 0) or O_NONBLOCK)
    return ForkServer(
      ostream: newFileStream(writef),
      istream: newFileStream(readf),
      estream: newPosixStream(pipefd_err[0])
    )
import std/exitprocs
import std/options
import std/os
import std/posix
import std/strutils
import std/tables

import chagashi/charset
import chagashi/decoder
import config/config
import html/catom
import html/chadombuilder
import html/dom
import html/domexception
import html/env
import html/formdata
import html/jsencoding
import html/jsintl
import html/xmlhttprequest
import io/bufwriter
import io/console
import io/dynstream
import io/poll
import io/promise
import io/timeout
import local/container
import local/lineedit
import local/pager
import local/select
import local/term
import monoucha/constcharp
import monoucha/fromjs
import monoucha/javascript
import monoucha/jserror
import monoucha/jsopaque
import monoucha/jstypes
import monoucha/jsutils
import monoucha/quickjs
import monoucha/tojs
import server/buffer
import server/forkserver
import server/headers
import server/loaderiface
import server/request
import server/response
import types/blob
import types/cookie
import types/opt
import types/url
import utils/twtstr

type
  Client* = ref object of Window
    alive: bool
    config {.jsget.}: Config
    feednext: bool
    pager {.jsget.}: Pager
    pressed: tuple[col, row: int]
    exitCode: int
    inEval: bool
    blockTillRelease: bool

  ContainerData = ref object of MapData
    container: Container

template pollData(client: Client): PollData =
  client.pager.pollData

template forkserver(client: Client): ForkServer =
  client.pager.forkserver

template readChar(client: Client): char =
  client.pager.term.readChar()

template consoleWrapper(client: Client): ConsoleWrapper =
  client.pager.consoleWrapper

func console(client: Client): Console {.jsfget.} =
  return client.consoleWrapper.console

proc interruptHandler(rt: JSRuntime; opaque: pointer): cint {.cdecl.} =
  let client = cast[Client](opaque)
  if client.console == nil or client.pager.term.istream == nil:
    return 0
  try:
    let c = client.pager.term.istream.sreadChar()
    if c == char(3): #C-c
      client.pager.term.ibuf = ""
      return 1
    else:
      client.pager.term.ibuf &= c
  except IOError:
    discard
  return 0

proc cleanup(client: Client) =
  if client.alive:
    client.alive = false
    client.pager.quit()
    for val in client.config.cmd.map.values:
      JS_FreeValue(client.jsctx, val)
    for fn in client.config.jsvfns:
      JS_FreeValue(client.jsctx, fn)
    client.timeouts.clearAll()
    assert not client.inEval
    client.jsctx.free()
    client.jsrt.free()

proc quit(client: Client; code = 0) =
  client.cleanup()
  quit(code)

proc runJSJobs(client: Client) =
  while true:
    let r = client.jsrt.runJSJobs()
    if r.isSome:
      break
    let ctx = r.error
    ctx.writeException(client.console.err)
  if client.exitCode != -1:
    client.quit(0)

proc evalJS(client: Client; src, filename: string; module = false): JSValue =
  client.pager.term.unblockStdin()
  let flags = if module:
    JS_EVAL_TYPE_MODULE
  else:
    JS_EVAL_TYPE_GLOBAL
  let wasInEval = client.inEval
  client.inEval = true
  result = client.jsctx.eval(src, filename, flags)
  client.inEval = false
  client.pager.term.restoreStdin()
  if client.exitCode != -1:
    # if we are in a nested eval, then just wait until we are not.
    if not wasInEval:
      client.quit(client.exitCode)
  else:
    client.runJSJobs()

proc evalJSFree(client: Client; src, filename: string) =
  JS_FreeValue(client.jsctx, client.evalJS(src, filename))

proc evalJSFree2(opaque: RootRef; src, filename: string) =
  let client = Client(opaque)
  client.evalJSFree(src, filename)

proc command0(client: Client; src: string; filename = "<command>";
    silence = false; module = false) =
  let ret = client.evalJS(src, filename, module = module)
  if JS_IsException(ret):
    client.jsctx.writeException(client.console.err)
  else:
    if not silence:
      var res: string
      if client.jsctx.fromJS(ret, res).isSome:
        client.console.log(res)
  JS_FreeValue(client.jsctx, ret)

proc command(client: Client; src: string) =
  client.command0(src)
  let container = client.consoleWrapper.container
  if container != nil:
    container.tailOnLoad = true

proc suspend(client: Client) {.jsfunc.} =
  client.pager.term.quit()
  discard kill(0, cint(SIGTSTP))
  client.pager.term.restart()

proc jsQuit(client: Client; code: uint32 = 0): JSValue {.jsfunc: "quit".} =
  client.exitCode = int(code)
  let ctx = client.jsctx
  let ctor = ctx.getOpaque().errCtorRefs[jeInternalError]
  let err = JS_CallConstructor(ctx, ctor, 0, nil)
  JS_SetUncatchableError(ctx, err, true);
  return JS_Throw(ctx, err)

proc feedNext(client: Client) {.jsfunc.} =
  client.feednext = true

proc alert(client: Client; msg: string) {.jsfunc.} =
  client.pager.alert(msg)

proc evalActionJS(client: Client; action: string): JSValue =
  if action.startsWith("cmd."):
    client.config.cmd.map.withValue(action.substr("cmd.".len), p):
      return JS_DupValue(client.jsctx, p[])
  return client.evalJS(action, "<command>")

# Warning: this is not re-entrant.
proc evalAction(client: Client; action: string; arg0: int32): EmptyPromise =
  var ret = client.evalActionJS(action)
  let ctx = client.jsctx
  var p = EmptyPromise()
  p.resolve()
  if JS_IsFunction(ctx, ret):
    if arg0 != 0:
      let arg0 = toJS(ctx, arg0)
      let ret2 = JS_Call(ctx, ret, JS_UNDEFINED, 1, arg0.toJSValueArray())
      JS_FreeValue(ctx, arg0)
      JS_FreeValue(ctx, ret)
      ret = ret2
    else: # no precnum
      let ret2 = JS_Call(ctx, ret, JS_UNDEFINED, 0, nil)
      JS_FreeValue(ctx, ret)
      ret = ret2
    if client.exitCode != -1:
      assert not client.inEval
      client.quit(client.exitCode)
  if JS_IsException(ret):
    client.jsctx.writeException(client.console.err)
  elif JS_IsObject(ret):
    var maybep: EmptyPromise
    if ctx.fromJS(ret, maybep).isSome:
      p = maybep
  JS_FreeValue(ctx, ret)
  return p

#TODO move mouse input handling somewhere else...
proc handleMouseInputGeneric(client: Client; input: MouseInput) =
  case input.button
  of mibLeft:
    case input.t
    of mitPress:
      client.pressed = (input.col, input.row)
    of mitRelease:
      if client.pressed != (-1, -1):
        let diff = (input.col - client.pressed.col,
          input.row - client.pressed.row)
        if diff[0] > 0:
          discard client.evalAction("cmd.buffer.scrollLeft", int32(diff[0]))
        elif diff[0] < 0:
          discard client.evalAction("cmd.buffer.scrollRight", -int32(diff[0]))
        if diff[1] > 0:
          discard client.evalAction("cmd.buffer.scrollUp", int32(diff[1]))
        elif diff[1] < 0:
          discard client.evalAction("cmd.buffer.scrollDown", -int32(diff[1]))
        client.pressed = (-1, -1)
    else: discard
  of mibWheelUp:
    if input.t == mitPress:
      discard client.evalAction("cmd.buffer.scrollUp", 5)
  of mibWheelDown:
    if input.t == mitPress:
      discard client.evalAction("cmd.buffer.scrollDown", 5)
  of mibWheelLeft:
    if input.t == mitPress:
      discard client.evalAction("cmd.buffer.scrollLeft", 5)
  of mibWheelRight:
    if input.t == mitPress:
      discard client.evalAction("cmd.buffer.scrollRight", 5)
  else: discard

proc handleMouseInput(client: Client; input: MouseInput; select: Select) =
  let y = select.fromy + input.row - select.y - 1 # one off because of border
  case input.button
  of mibRight:
    if (input.col, input.row) != client.pressed:
      # Prevent immediate movement/submission in case the menu appeared under
      # the cursor.
      select.setCursorY(y)
    case input.t
    of mitPress:
      # Do not include borders, so that a double right click closes the
      # menu again.
      if input.row notin select.y + 1 ..< select.y + select.height - 1 or
          input.col notin select.x + 1 ..< select.x + select.width - 1:
        client.blockTillRelease = true
        select.cursorLeft()
    of mitRelease:
      if input.row in select.y + 1 ..< select.y + select.height - 1 and
          input.col in select.x + 1 ..< select.x + select.width - 1 and
          (input.col, input.row) != client.pressed:
        select.click()
      # forget about where we started once btn3 is released
      client.pressed = (-1, -1)
    of mitMove: discard
  of mibLeft:
    case input.t
    of mitPress:
      if input.row notin select.y ..< select.y + select.height or
          input.col notin select.x ..< select.x + select.width:
        # clicked outside the select
        client.blockTillRelease = true
        select.cursorLeft()
    of mitRelease:
      let at = (input.col, input.row)
      if at == client.pressed and
          (input.row in select.y + 1 ..< select.y + select.height - 1 and
            input.col in select.x + 1 ..< select.x + select.width - 1 or
          select.multiple and at == (select.x, select.y)):
        # clicked inside the select
        select.setCursorY(y)
        select.click()
    of mitMove: discard
  else: discard

proc handleMouseInput(client: Client; input: MouseInput; container: Container) =
  case input.button
  of mibLeft:
    if input.t == mitRelease and client.pressed == (input.col, input.row):
      let prevx = container.cursorx
      let prevy = container.cursory
      #TODO I wish we could avoid setCursorXY if we're just going to
      # click, but that doesn't work with double-width chars
      container.setCursorXY(container.fromx + input.col,
        container.fromy + input.row)
      if container.cursorx == prevx and container.cursory == prevy:
        discard client.evalAction("cmd.buffer.click", 0)
  of mibMiddle:
    if input.t == mitRelease: # release, to emulate w3m
      discard client.evalAction("cmd.pager.discardBuffer", 0)
  of mibRight:
    if input.t == mitPress: # w3m uses release, but I like this better
      client.pressed = (input.col, input.row)
      container.setCursorXY(container.fromx + input.col,
        container.fromy + input.row)
      client.pager.openMenu(input.col, input.row)
  of mibThumbInner:
    if input.t == mitPress:
      discard client.evalAction("cmd.pager.prevBuffer", 0)
  of mibThumbTip:
    if input.t == mitPress:
      discard client.evalAction("cmd.pager.nextBuffer", 0)
  else: discard

proc handleMouseInput(client: Client; input: MouseInput) =
  if client.blockTillRelease:
    if input.t == mitRelease:
      client.blockTillRelease = false
    else:
      return
  if client.pager.menu != nil:
    client.handleMouseInput(input, client.pager.menu)
  elif (let container = client.pager.container; container != nil):
    if container.select != nil:
      client.handleMouseInput(input, container.select)
    else:
      client.handleMouseInput(input, container)
  if not client.blockTillRelease:
    client.handleMouseInputGeneric(input)

# The maximum number we are willing to accept.
# This should be fine for 32-bit signed ints (which precnum currently is).
# We can always increase it further (e.g. by switching to uint32, uint64...) if
# it proves to be too low.
const MaxPrecNum = 100000000

proc handleCommandInput(client: Client; c: char): EmptyPromise =
  if client.config.input.vi_numeric_prefix and not client.pager.notnum:
    if client.pager.precnum != 0 and c == '0' or c in '1' .. '9':
      if client.pager.precnum < MaxPrecNum: # better ignore than eval...
        client.pager.precnum *= 10
        client.pager.precnum += cast[int32](decValue(c))
      return
    else:
      client.pager.notnum = true
  client.pager.inputBuffer &= c
  let action = getNormalAction(client.config, client.pager.inputBuffer)
  if action != "":
    let p = client.evalAction(action, client.pager.precnum)
    if not client.feednext:
      client.pager.precnum = 0
      client.pager.notnum = false
      client.pager.handleEvents()
    return p
  if client.config.input.use_mouse:
    if client.pager.inputBuffer == "\e[<":
      let input = client.pager.term.parseMouseInput()
      if input.isSome:
        let input = input.get
        client.handleMouseInput(input)
      client.pager.inputBuffer = ""
    elif "\e[<".startsWith(client.pager.inputBuffer):
      client.feednext = true
  return nil

proc input(client: Client): EmptyPromise =
  var p: EmptyPromise = nil
  client.pager.term.restoreStdin()
  var buf: string
  while true:
    let c = client.readChar()
    if client.pager.askpromise != nil:
      if c == 'y':
        client.pager.fulfillAsk(true)
      elif c == 'n':
        client.pager.fulfillAsk(false)
    elif client.pager.askcharpromise != nil:
      buf &= c
      if buf.validateUtf8Surr() != -1:
        continue
      client.pager.fulfillCharAsk(buf)
    elif client.pager.lineedit != nil:
      client.pager.inputBuffer &= c
      let edit = client.pager.lineedit
      if edit.escNext:
        edit.escNext = false
        if edit.write(client.pager.inputBuffer, client.pager.term.cs):
          client.pager.inputBuffer = ""
      else:
        let action = getLinedAction(client.config, client.pager.inputBuffer)
        if action == "":
          if edit.write(client.pager.inputBuffer, client.pager.term.cs):
            client.pager.inputBuffer = ""
          else:
            client.feednext = true
        elif not client.feednext:
          discard client.evalAction(action, 0)
        if not client.feednext:
          client.pager.updateReadLine()
    else:
      p = client.handleCommandInput(c)
      if not client.feednext:
        client.pager.inputBuffer = ""
        client.pager.refreshStatusMsg()
        break
      #TODO this is not perfect, because it results in us never displaying
      # lone escape. maybe a timeout for escape display would be useful
      if not "\e[<".startsWith(client.pager.inputBuffer):
        client.pager.refreshStatusMsg()
        client.pager.draw()
    if not client.feednext:
      client.pager.inputBuffer = ""
      break
    else:
      client.feednext = false
  client.pager.inputBuffer = ""
  if p == nil:
    p = newResolvedPromise()
  return p

proc consoleBuffer(client: Client): Container {.jsfget.} =
  return client.consoleWrapper.container

proc acceptBuffers(client: Client) =
  let pager = client.pager
  while pager.unreg.len > 0:
    let container = pager.unreg.pop()
    if container.iface != nil: # fully connected
      let stream = container.iface.stream
      let fd = int(stream.source.fd)
      client.pollData.unregister(fd)
      client.loader.unset(fd)
      stream.sclose()
    elif container.process != -1: # connecting to buffer process
      let i = pager.findProcMapItem(container.process)
      pager.procmap.del(i)
    elif (let item = pager.findConnectingContainer(container); item != nil):
      # connecting to URL
      let stream = item.stream
      client.pollData.unregister(int(stream.fd))
      stream.sclose()
      client.loader.unset(item)
  let registerFun = proc(fd: int) =
    client.pollData.unregister(fd)
    client.pollData.register(fd, POLLIN or POLLOUT)
  for item in pager.procmap:
    let container = item.container
    let stream = connectSocketStream(client.config.external.sockdir,
      client.loader.sockDirFd, container.process)
    # unlink here; on Linux we can't unlink from the buffer :/
    discard tryRemoveFile(getSocketPath(client.config.external.sockdir,
      container.process))
    if stream == nil:
      pager.alert("Error: failed to set up buffer")
      continue
    let key = pager.addLoaderClient(container.process, container.loaderConfig,
      container.clonedFrom)
    let loader = pager.loader
    if item.istreamOutputId != -1: # new buffer
      if container.cacheId == -1:
        container.cacheId = loader.addCacheFile(item.istreamOutputId,
          loader.clientPid)
      if container.request.url.scheme == "cache":
        # loading from cache; now both the buffer and us hold a new reference
        # to the cached item, but it's only shared with the buffer. add a
        # pager ref too.
        loader.shareCachedItem(container.cacheId, loader.clientPid)
      let pid = container.process
      var outCacheId = container.cacheId
      if not item.redirected:
        loader.shareCachedItem(container.cacheId, pid)
        loader.resume(item.istreamOutputId)
      else:
        outCacheId = loader.addCacheFile(item.ostreamOutputId, pid)
        loader.resume([item.istreamOutputId, item.ostreamOutputId])
      stream.withPacketWriter w:
        w.swrite(key)
        w.swrite(outCacheId)
      # pass down ostream
      # must come after the previous block so the first packet is flushed
      stream.sendFd(item.ostream.fd)
      item.ostream.sclose()
      container.setStream(stream, registerFun)
    else: # cloned buffer
      stream.withPacketWriter w:
        w.swrite(key)
      # buffer is cloned, just share the parent's cached source
      loader.shareCachedItem(container.cacheId, container.process)
      # also add a reference here; it will be removed when the container is
      # deleted
      loader.shareCachedItem(container.cacheId, loader.clientPid)
      container.setCloneStream(stream, registerFun)
    let fd = int(stream.fd)
    client.loader.put(ContainerData(stream: stream, container: container))
    client.pollData.register(fd, POLLIN)
    # clear replacement references, because we can't fail to load this
    # buffer anymore
    container.replaceRef = nil
    container.replace = nil
    container.replaceBackup = nil
    pager.handleEvents(container)
  pager.procmap.setLen(0)

proc handleStderr(client: Client) =
  const BufferSize = 4096
  const prefix = "STDERR: "
  var buffer {.noinit.}: array[BufferSize, char]
  let estream = client.forkserver.estream
  var hadlf = true
  while true:
    try:
      let n = estream.recvData(buffer)
      if n == 0:
        break
      var i = 0
      while i < n:
        var j = n
        var found = false
        for k in i ..< n:
          if buffer[k] == '\n':
            j = k + 1
            found = true
            break
        if hadlf:
          client.console.err.write(prefix)
        if j - i > 0:
          client.console.err.write(buffer.toOpenArray(i, j - 1))
        i = j
        hadlf = found
    except ErrorAgain:
      break
  if not hadlf:
    client.console.err.write('\n')
  client.console.err.sflush()

proc handleRead(client: Client; fd: int) =
  if client.pager.term.istream != nil and fd == client.pager.term.istream.fd:
    client.input().then(proc() =
      client.pager.handleEvents()
    )
  elif fd == client.forkserver.estream.fd:
    client.handleStderr()
  elif (let data = client.loader.get(fd); data != nil):
    if data of ConnectingContainer:
      client.pager.handleRead(ConnectingContainer(data))
    elif data of ContainerData:
      let container = ContainerData(data).container
      client.pager.handleEvent(container)
    else:
      client.loader.onRead(fd)
      if data of ConnectData:
        client.runJSJobs()
  elif fd in client.loader.unregistered:
    discard # ignore
  else:
    assert false

proc handleWrite(client: Client; fd: int) =
  let container = ContainerData(client.loader.get(fd)).container
  if container.iface.stream.flushWrite():
    client.pollData.unregister(fd)
    client.pollData.register(fd, POLLIN)

proc flushConsole*(client: Client) {.jsfunc.} =
  client.pager.flushConsole()
  client.handleRead(client.forkserver.estream.fd)

proc handleError(client: Client; fd: int) =
  if client.pager.term.istream != nil and fd == client.pager.term.istream.fd:
    #TODO do something here...
    stderr.write("Error in tty\n")
    client.quit(1)
  elif fd == client.forkserver.estream.fd:
    #TODO do something here...
    stderr.write("Fork server crashed :(\n")
    client.quit(1)
  elif (let data = client.loader.get(fd); data != nil):
    if data of ConnectingContainer:
      client.pager.handleError(ConnectingContainer(data))
    elif data of ContainerData:
      let container = ContainerData(data).container
      if container != client.consoleWrapper.container:
        client.console.error("Error in buffer", $container.url)
      else:
        client.consoleWrapper.container = nil
      client.pollData.unregister(fd)
      client.loader.unset(fd)
      doAssert client.consoleWrapper.container != nil
      client.pager.showConsole()
    else:
      discard client.loader.onError(fd) #TODO handle connection error?
  elif fd in client.loader.unregistered:
    discard # already unregistered...
  else:
    doAssert client.consoleWrapper.container != nil
    client.pager.showConsole()

let SIGWINCH {.importc, header: "<signal.h>", nodecl.}: cint

proc setupSigwinch(client: Client): PosixStream =
  var pipefd {.noinit.}: array[2, cint]
  doAssert pipe(pipefd) != -1
  let writer = newPosixStream(pipefd[1])
  writer.setBlocking(false)
  var gwriter {.global.}: PosixStream = nil
  gwriter = writer
  onSignal SIGWINCH:
    discard sig
    try:
      gwriter.sendDataLoop([0u8])
    except ErrorAgain:
      discard
  let reader = newPosixStream(pipefd[0])
  reader.setBlocking(false)
  return reader

proc inputLoop(client: Client) =
  client.pollData.register(client.pager.term.istream.fd, POLLIN)
  let sigwinch = client.setupSigwinch()
  client.pollData.register(sigwinch.fd, POLLIN)
  while true:
    let timeout = client.timeouts.sortAndGetTimeout()
    client.pollData.poll(timeout)
    for event in client.pollData.events:
      let efd = int(event.fd)
      if (event.revents and POLLIN) != 0:
        if event.fd == sigwinch.fd:
          sigwinch.drain()
          client.pager.windowChange()
        else:
          client.handleRead(efd)
      if (event.revents and POLLOUT) != 0:
        client.handleWrite(efd)
      if (event.revents and POLLERR) != 0 or (event.revents and POLLHUP) != 0:
        client.handleError(efd)
    if client.timeouts.run(client.console.err):
      let container = client.consoleWrapper.container
      if container != nil:
        container.tailOnLoad = true
    client.runJSJobs()
    client.loader.unregistered.setLen(0)
    client.acceptBuffers()
    if client.pager.scommand != "":
      client.command(client.pager.scommand)
      client.pager.scommand = ""
      client.pager.handleEvents()
    if client.pager.container == nil and client.pager.lineedit == nil:
      # No buffer to display.
      if not client.pager.hasload:
        # Failed to load every single URL the user passed us. We quit, and that
        # will dump all alerts to stderr.
        client.quit(1)
      else:
        # At least one connection has succeeded, but we have nothing to display.
        # Normally, this means that the input stream has been redirected to a
        # file or to an external program. That also means we can't just exit
        # without potentially interrupting that stream.
        #TODO: a better UI would be querying the number of ongoing streams in
        # loader, and then asking for confirmation if there is at least one.
        client.pager.term.setCursor(0, client.pager.term.attrs.height - 1)
        client.pager.term.anyKey("Hit any key to quit Chawan:")
        client.quit(0)
    client.pager.showAlerts()
    client.pager.draw()

func hasSelectFds(client: Client): bool =
  return not client.timeouts.empty or
    client.pager.numload > 0 or
    client.loader.mapFds > 0 or
    client.pager.procmap.len > 0

proc headlessLoop(client: Client) =
  while client.hasSelectFds():
    let timeout = client.timeouts.sortAndGetTimeout()
    client.pollData.poll(timeout)
    for event in client.pollData.events:
      let efd = int(event.fd)
      if (event.revents and POLLIN) != 0:
        client.handleRead(efd)
      if (event.revents and POLLOUT) != 0:
        client.handleWrite(efd)
      if (event.revents and POLLERR) != 0 or (event.revents and POLLHUP) != 0:
        client.handleError(efd)
    discard client.timeouts.run(client.console.err)
    client.runJSJobs()
    client.loader.unregistered.setLen(0)
    client.acceptBuffers()

proc setImportMeta(ctx: JSContext; funcVal: JSValue; isMain: bool) =
  let m = cast[JSModuleDef](JS_VALUE_GET_PTR(funcVal))
  let moduleNameAtom = JS_GetModuleName(ctx, m)
  let metaObj = JS_GetImportMeta(ctx, m)
  definePropertyCWE(ctx, metaObj, "url", JS_AtomToValue(ctx, moduleNameAtom))
  definePropertyCWE(ctx, metaObj, "main", isMain)
  JS_FreeValue(ctx, metaObj)
  JS_FreeAtom(ctx, moduleNameAtom)

proc finishLoadModule(ctx: JSContext; f: string; name: cstring): JSModuleDef =
  let funcVal = compileModule(ctx, f, $name)
  if JS_IsException(funcVal):
    return nil
  setImportMeta(ctx, funcVal, false)
  # "the module is already referenced, so we must free it"
  # idk how this works, so for now let's just do what qjs does
  result = cast[JSModuleDef](JS_VALUE_GET_PTR(funcVal))
  JS_FreeValue(ctx, funcVal)

proc normalizeModuleName(ctx: JSContext; base_name, name: cstringConst;
    opaque: pointer): cstring {.cdecl.} =
  return js_strdup(ctx, cstring(name))

proc clientLoadJSModule(ctx: JSContext; module_name: cstringConst;
    opaque: pointer): JSModuleDef {.cdecl.} =
  let global = JS_GetGlobalObject(ctx)
  JS_FreeValue(ctx, global)
  var x: Option[URL]
  if module_name[0] == '/' or module_name[0] == '.' and
      (module_name[1] == '/' or
      module_name[1] == '.' and module_name[2] == '/'):
    let cur = getCurrentDir()
    x = parseURL($module_name, parseURL("file://" & cur & "/"))
  else:
    x = parseURL($module_name)
  if x.isNone or x.get.scheme != "file":
    JS_ThrowTypeError(ctx, "Invalid URL: %s", module_name)
    return nil
  try:
    let f = readFile(x.get.pathname)
    return finishLoadModule(ctx, f, cstring(module_name))
  except IOError:
    JS_ThrowTypeError(ctx, "Failed to open file %s", module_name)
    return nil

proc readBlob(client: Client; path: string): WebFile {.jsfunc.} =
  let ps = newPosixStream(path, O_RDONLY, 0)
  if ps == nil:
    return nil
  let name = path.afterLast('/')
  return newWebFile(name, ps.fd)

#TODO this is dumb
proc readFile(client: Client; path: string): string {.jsfunc.} =
  try:
    return readFile(path)
  except IOError:
    discard

#TODO ditto
proc writeFile(client: Client; path, content: string) {.jsfunc.} =
  writeFile(path, content)

proc dumpBuffers(client: Client) =
  client.headlessLoop()
  for container in client.pager.containers:
    try:
      client.pager.drawBuffer(container, stdout)
      client.pager.handleEvents(container)
    except IOError:
      client.console.error("Error in buffer", $container.url)
      # check for errors
      client.handleRead(client.forkserver.estream.fd)
      client.quit(1)

proc launchClient*(client: Client; pages: seq[string];
    contentType: Option[string]; cs: Charset; dump: bool) =
  var istream: PosixStream
  var dump = dump
  if not dump:
    if stdin.isatty():
      istream = newPosixStream(STDIN_FILENO)
    if stdout.isatty():
      if istream == nil:
        istream = newPosixStream("/dev/tty", O_RDONLY, 0)
    else:
      istream = nil
    dump = istream == nil
  let pager = client.pager
  pager.pollData.register(client.forkserver.estream.fd, POLLIN)
  client.loader.registerFun = proc(fd: int) =
    pager.pollData.register(fd, POLLIN)
  client.loader.unregisterFun = proc(fd: int) =
    pager.pollData.unregister(fd)
  pager.launchPager(istream)
  client.timeouts = newTimeoutState(client.jsctx, evalJSFree2, client)
  client.pager.timeouts = client.timeouts
  addExitProc((proc() = client.cleanup()))
  if client.config.start.startup_script != "":
    let s = if fileExists(client.config.start.startup_script):
      readFile(client.config.start.startup_script)
    else:
      client.config.start.startup_script
    let ismodule = client.config.start.startup_script.endsWith(".mjs")
    client.command0(s, client.config.start.startup_script, silence = true,
      module = ismodule)
  if not stdin.isatty():
    # stdin may very well receive ANSI text
    let contentType = contentType.get("text/x-ansi")
    let ps = newPosixStream(STDIN_FILENO)
    client.pager.readPipe(contentType, cs, ps, "*stdin*")
  for page in pages:
    client.pager.loadURL(page, ctype = contentType, cs = cs)
  client.pager.showAlerts()
  client.acceptBuffers()
  if not dump:
    client.inputLoop()
  else:
    client.dumpBuffers()
  if client.config.start.headless:
    client.headlessLoop()

proc nimGCStats(client: Client): string {.jsfunc.} =
  return GC_getStatistics()

proc jsGCStats(client: Client): string {.jsfunc.} =
  return client.jsrt.getMemoryUsage()

proc nimCollect(client: Client) {.jsfunc.} =
  GC_fullCollect()

proc jsCollect(client: Client) {.jsfunc.} =
  JS_RunGC(client.jsrt)

proc sleep(client: Client; millis: int) {.jsfunc.} =
  sleep millis

func line(client: Client): LineEdit {.jsfget.} =
  return client.pager.lineedit

proc addJSModules(client: Client; ctx: JSContext) =
  ctx.addWindowModule2()
  ctx.addDOMExceptionModule()
  ctx.addConsoleModule()
  ctx.addNavigatorModule()
  ctx.addDOMModule()
  ctx.addURLModule()
  ctx.addHTMLModule()
  ctx.addIntlModule()
  ctx.addBlobModule()
  ctx.addFormDataModule()
  ctx.addXMLHttpRequestModule()
  ctx.addHeadersModule()
  ctx.addRequestModule()
  ctx.addResponseModule()
  ctx.addEncodingModule()
  ctx.addLineEditModule()
  ctx.addConfigModule()
  ctx.addPagerModule()
  ctx.addContainerModule()
  ctx.addSelectModule()
  ctx.addCookieModule()

func getClient(client: Client): Client {.jsfget: "client".} =
  return client

proc newClient*(config: Config; forkserver: ForkServer; loaderPid: int;
    jsctx: JSContext; warnings: seq[string]; urandom: PosixStream): Client =
  setControlCHook(proc() {.noconv.} = quit(1))
  let jsrt = JS_GetRuntime(jsctx)
  JS_SetModuleLoaderFunc(jsrt, normalizeModuleName, clientLoadJSModule, nil)
  let loader = FileLoader(process: loaderPid, clientPid: getCurrentProcessId())
  loader.setSocketDir(config.external.sockdir)
  let client = Client(
    config: config,
    jsrt: jsrt,
    jsctx: jsctx,
    exitCode: -1,
    alive: true,
    factory: newCAtomFactory(),
    loader: loader,
    urandom: urandom
  )
  client.pager = newPager(config, forkserver, jsctx, warnings, urandom,
    proc(action: string; arg0: int32) =
      discard client.evalAction(action, arg0)
  )
  client.pager.setLoader(loader)
  JS_SetInterruptHandler(jsrt, interruptHandler, cast[pointer](client))
  let global = JS_GetGlobalObject(jsctx)
  jsctx.setGlobal(client)
  jsctx.definePropertyE(global, "cmd", config.cmd.jsObj)
  JS_FreeValue(jsctx, global)
  config.cmd.jsObj = JS_NULL
  client.addJSModules(jsctx)
  let windowCID = jsctx.getClass("Window")
  jsctx.registerType(Client, asglobal = true, parent = windowCID)
  return client

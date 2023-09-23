import strutils

import bindings/curl
import loader/connecterror
import loader/curlhandle
import loader/curlwrap
import loader/dirlist
import loader/headers
import loader/loaderhandle
import loader/request
import types/opt
import types/url
import utils/twtstr

type FtpHandle = ref object of CurlHandle
  buffer: string
  dirmode: bool
  base: string
  path: string

func newFtpHandle(curl: CURL, request: Request, handle: LoaderHandle,
    dirmode: bool): FtpHandle =
  return FtpHandle(
    headers: newHeaders(),
    curl: curl,
    handle: handle,
    request: request,
    dirmode: dirmode
  )

proc curlWriteHeader(p: cstring, size: csize_t, nitems: csize_t,
    userdata: pointer): csize_t {.cdecl.} =
  var line = newString(nitems)
  if nitems > 0:
    prepareMutation(line)
    copyMem(addr line[0], p, nitems)

  let op = cast[FtpHandle](userdata)

  if not op.statusline:
    if line.startsWith("150") or line.startsWith("125"):
      op.statusline = true
      if not op.handle.sendResult(int(CURLE_OK)):
        return 0
      var status: clong
      op.curl.getinfo(CURLINFO_RESPONSE_CODE, addr status)
      if not op.handle.sendStatus(cast[int](status)):
        return 0
      if op.dirmode:
        op.headers.add("Content-Type", "text/html")
      if not op.handle.sendHeaders(op.headers):
        return 0
      if op.dirmode:
        if not op.handle.sendData("""
<HTML>
<HEAD>
<BASE HREF=""" & op.base & """>
<TITLE>""" & op.path & """</TITLE>
</HEAD>
<BODY>
<H1>Index of """ & htmlEscape(op.path) & """</H1>
<PRE>
"""):
          return 0
      return nitems
    elif line.startsWith("530"): # login incorrect
      op.statusline = true
      if not op.handle.sendResult(int(CURLE_OK)):
        return 0
      var status: clong
      op.curl.getinfo(CURLINFO_RESPONSE_CODE, addr status)
      discard op.handle.sendStatus(401) # unauthorized (shim http)
      op.headers.add("Content-Type", "text/html")
      discard op.handle.sendHeaders(op.headers)
      discard op.handle.sendData("""
<HTML>
<HEAD>
<TITLE>Unauthorized</TITLE>
</HEAD>
<BODY>
<PRE>
""" & htmlEscape(line))
      return 0
  return nitems

# From the documentation: size is always 1.
proc curlWriteBody(p: cstring, size: csize_t, nmemb: csize_t,
    userdata: pointer): csize_t {.cdecl.} =
  let op = cast[FtpHandle](userdata)

  if nmemb > 0:
    if op.dirmode:
      let i = op.buffer.len
      op.buffer.setLen(op.buffer.len + int(nmemb))
      prepareMutation(op.buffer)
      copyMem(addr op.buffer[i], p, nmemb)
    else:
      if not op.handle.sendData(p, int(nmemb)):
        return 0
  return nmemb

proc finish(op: CurlHandle) =
  let op = cast[FtpHandle](op)
  var items: seq[DirlistItem]
  for line in op.buffer.split('\n'):
    if line.len == 0: continue
    var i = 10 # permission
    template skip_till_space =
      while i < line.len and line[i] != ' ':
        inc i
    # link count
    i = line.skipBlanks(i)
    while i < line.len and line[i] in AsciiDigit:
      inc i
    # owner
    i = line.skipBlanks(i)
    skip_till_space
    # group
    i = line.skipBlanks(i)
    while i < line.len and line[i] != ' ':
      inc i
    # size
    i = line.skipBlanks(i)
    var sizes = ""
    while i < line.len and line[i] in AsciiDigit:
      sizes &= line[i]
      inc i
    let nsize = parseInt64(sizes).get(-1)
    # date
    i = line.skipBlanks(i)
    let datestarti = i
    skip_till_space # m
    i = line.skipBlanks(i)
    skip_till_space # d
    i = line.skipBlanks(i)
    skip_till_space # y
    let dates = line.substr(datestarti, i)
    inc i
    let name = line.substr(i)
    if name == "." or name == "..": continue
    case line[0]
    of 'l': # link
      let x = " -> "
      let linki = name.find(x)
      let linkfrom = name.substr(0, linki - 1)
      let linkto = name.substr(linki + 4) # you?
      items.add(DirlistItem(
        t: ITEM_LINK,
        name: linkfrom,
        modified: dates,
        linkto: linkto
      ))
    of 'd': # directory
      items.add(DirlistItem(
        t: ITEM_DIR,
        name: name,
        modified: dates
      ))
    else: # file
      items.add(DirlistItem(
        t: ITEM_FILE,
        name: name,
        modified: dates,
        nsize: int(nsize)
      ))
  discard op.handle.sendData(makeDirlist(items))
  discard op.handle.sendData("\n</PRE>\n</BODY>\n</HTML>\n")

proc loadFtp*(handle: LoaderHandle, curlm: CURLM,
    request: Request): CurlHandle =
  let curl = curl_easy_init()
  doAssert curl != nil
  let surl = request.url.serialize()
  let path = request.url.path.serialize_unicode()
  # By default, cURL CWD's into relative paths, and an extra slash is
  # necessary to specify absolute paths.
  # This is incredibly confusing, and probably not what the user wanted.
  # So we work around it by adding the extra slash ourselves.
  let hackurl = newURL(request.url)
  hackurl.setPathname('/' & request.url.pathname)
  let csurl = hackurl.serialize()
  curl.setopt(CURLOPT_URL, csurl)
  let dirmode = path.len > 0 and path[^1] == '/'
  let handleData = curl.newFtpHandle(request, handle, dirmode)
  curl.setopt(CURLOPT_HEADERDATA, handleData)
  curl.setopt(CURLOPT_HEADERFUNCTION, curlWriteHeader)
  curl.setopt(CURLOPT_WRITEDATA, handleData)
  curl.setopt(CURLOPT_WRITEFUNCTION, curlWriteBody)
  curl.setopt(CURLOPT_FTP_FILEMETHOD, CURLFTPMETHOD_SINGLECWD)
  if dirmode:
    handleData.finish = finish
    handleData.base = surl
    handleData.path = path
  if request.proxy != nil:
    let purl = request.proxy.serialize()
    curl.setopt(CURLOPT_PROXY, purl)
  if request.httpmethod != HTTP_GET:
    discard handle.sendResult(int(ERROR_INVALID_METHOD))
    return nil
  let res = curl_multi_add_handle(curlm, curl)
  if res != CURLM_OK:
    discard handle.sendResult(int(res))
    return nil
  return handleData
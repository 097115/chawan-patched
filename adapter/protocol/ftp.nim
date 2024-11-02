import std/options
import std/os
import std/posix
import std/strutils

import lcgi

import utils/twtstr

proc sendCommand(os, ps: PosixStream; cmd, param: string; outs: var string):
    int32 =
  if cmd != "":
    if param == "":
      ps.sendDataLoop(cmd & "\r\n")
    else:
      ps.sendDataLoop(cmd & ' ' & param & "\r\n")
  var buf = newString(4)
  try:
    ps.recvDataLoop(buf)
  except EOFError:
    os.die("InvalidResponse")
  if buf.len < 4:
    os.die("InvalidResponse")
  outs = ""
  while (let c = ps.sreadChar(); c != '\n'):
    outs &= c
  let status = parseInt32(buf.toOpenArray(0, 2)).get(-1)
  if buf[3] == ' ':
    return status
  buf[3] = ' '
  while true: # multiline
    var lbuf = ""
    while (let c = ps.sreadChar(); c != '\n'):
      lbuf &= c
    outs &= lbuf
    if lbuf.startsWith(buf):
      break
  return status

proc sdie(os: PosixStream; status: int; s, obuf: string) {.noreturn.} =
  os.sendDataLoop("Status: " & $status & "\nContent-Type: text/html\n\n" & """
<h1>""" & s & """</h1>

The server has returned the following message:

<plaintext>
""" & obuf)

const Success = 200 .. 299
proc passiveMode(os, ps: PosixStream; host: string; ipv6: bool): PosixStream =
  var obuf = ""
  if ipv6:
    if os.sendCommand(ps, "EPSV", "", obuf) != 229:
      os.die("InvalidResponse")
    var i = obuf.find('(')
    if i == -1:
      os.die("InvalidResponse")
    i += 4 # skip delims
    let j = obuf.find(')', i)
    if j == -1:
      os.die("InvalidResponse")
    let port = obuf.substr(i, j - 2)
    return os.connectSocket(host, port)
  if os.sendCommand(ps, "PASV", "", obuf) notin Success:
    os.sdie(500, "Couldn't enter passive mode", obuf)
  let i = obuf.find(AsciiDigit)
  if i == -1:
    os.die("InvalidResponse")
  var j = obuf.find(AllChars - AsciiDigit - {','}, i)
  if j == -1:
    j = obuf.len
  let ss = obuf.substr(i, j - 1).split(',')
  if ss.len < 6:
    os.die("InvalidResponse")
  var ipv4 = ss[0]
  for x in ss.toOpenArray(1, 3):
    ipv4 &= '.'
    ipv4 &= x
  let x = parseUInt16(ss[4])
  let y = parseUInt16(ss[5])
  if x.isNone or y.isNone:
    os.die("InvalidResponse")
  let port = $((x.get shl 8) or y.get)
  return os.connectSocket(host, port)

proc main() =
  let os = newPosixStream(STDOUT_FILENO)
  let host = getEnv("MAPPED_URI_HOST")
  let username = getEnv("MAPPED_URI_USERNAME")
  let password = getEnv("MAPPED_URI_PASSWORD")
  let port = getEnvEmpty("MAPPED_URI_PORT", "21")
  if getEnv("REQUEST_METHOD") != "GET":
    os.die("InvalidMethod")
  var ipv6: bool
  let ps = os.connectSocket(host, port, ipv6)
  var obuf = ""
  if os.sendCommand(ps, "", "", obuf) != 220:
    let s = obuf.deleteChars({'\n', '\r'})
    os.die("ConnectionRefused " & s)
  var ustatus = os.sendCommand(ps, "USER", username, obuf)
  if ustatus == 331:
    ustatus = os.sendCommand(ps, "PASS", password, obuf)
  if ustatus in Success:
    discard # no need for pass
  else:
    os.sdie(401, "Unauthorized", obuf)
  discard os.sendCommand(ps, "TYPE", "I", obuf) # request raw data
  let passive = os.passiveMode(ps, host, ipv6)
  enterNetworkSandbox()
  var path = percentDecode(getEnvEmpty("MAPPED_URI_PATH", "/"))
  if os.sendCommand(ps, "CWD", path, obuf) == 250:
    if path[^1] != '/':
      os.sendDataLoop("Status: 301\nLocation: " & path & "/\n")
      quit(0)
    discard os.sendCommand(ps, "LIST", "", obuf)
    let title = percentEncode("Index of " & path, ComponentPercentEncodeSet)
    os.sendDataLoop("Content-Type: text/x-dirlist;title=" & title & "\n\n")
  else:
    if os.sendCommand(ps, "RETR", path, obuf) == 550:
      os.sdie(404, "Not found", obuf)
    os.sendDataLoop("\n")
  var buffer {.noinit.}: array[4096, uint8]
  while true:
    let n = passive.recvData(buffer)
    if n == 0:
      break
    os.sendDataLoop(buffer.toOpenArray(0, n - 1))

main()

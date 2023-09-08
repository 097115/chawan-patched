# Interface for QuickJS libregexp.
import unicode

import bindings/libregexp
import bindings/quickjs
import utils/opt
import utils/twtstr

export
  LRE_FLAG_GLOBAL,
  LRE_FLAG_IGNORECASE,
  LRE_FLAG_MULTILINE,
  LRE_FLAG_DOTALL,
  LRE_FLAG_UTF16,
  LRE_FLAG_STICKY

type
  Regex* = object
    bytecode*: ptr uint8
    plen*: cint
    clone*: bool
    buf*: string

  RegexResult* = object
    success*: bool
    captures*: seq[tuple[s, e: int]] # start, end

  RegexReplace* = object
    regex: Regex
    rule: string
    global: bool

var dummyRuntime = JS_NewRuntime()
var dummyContext = JS_NewContextRaw(dummyRuntime)

when NimMajor >= 2:
  proc `=destroy`*(regex: Regex) =
    if regex.bytecode != nil:
      if regex.clone:
        dealloc(regex.bytecode)
      else:
        dummyRuntime.js_free_rt(regex.bytecode)
else:
  proc `=destroy`*(regex: var Regex) =
    if regex.bytecode != nil:
      if regex.clone:
        dealloc(regex.bytecode)
      else:
        dummyRuntime.js_free_rt(regex.bytecode)
      regex.bytecode = nil

proc `=copy`*(dest: var Regex, source: Regex) =
  if dest.bytecode != source.bytecode:
    `=destroy`(dest)
    wasMoved(dest)
    dest.bytecode = cast[ptr uint8](alloc(source.plen))
    copyMem(dest.bytecode, source.bytecode, source.plen)
    dest.clone = true
    dest.buf = source.buf
    dest.plen = source.plen

func `$`*(regex: Regex): string =
  regex.buf

proc compileRegex*(buf: string, flags: int): Result[Regex, string] =
  var regex: Regex
  var error_msg_size = 64
  var error_msg = newString(error_msg_size)
  prepareMutation(error_msg)
  let bytecode = lre_compile(addr regex.plen, cstring(error_msg),
    cint(error_msg_size), cstring(buf), csize_t(buf.len), cint(flags),
    dummyContext)
  if bytecode == nil:
    return err(error_msg.until('\0')) # Failed to compile.
  regex.buf = buf
  regex.bytecode = bytecode
  return ok(regex)

func countBackslashes(buf: string, i: int): int =
  var j = 0
  for i in countdown(i, 0):
    if buf[i] != '\\':
      break
    inc j
  return j

# ^abcd -> ^abcd
# efgh$ -> efgh$
# ^ijkl$ -> ^ijkl$
# mnop -> ^mnop$
proc compileMatchRegex*(buf: string): Result[Regex, string] =
  if buf.len == 0:
    return compileRegex(buf, 0)
  if buf[0] == '^':
    return compileRegex(buf, 0)
  if buf[^1] == '$':
    # Check whether the final dollar sign is escaped.
    if buf.len == 1 or buf[^2] != '\\':
      return compileRegex(buf, 0)
    let j = buf.countBackslashes(buf.high - 2)
    if j mod 2 == 1: # odd, because we do not count the last backslash
      return compileRegex(buf, 0)
    # escaped. proceed as if no dollar sign was at the end
  if buf[^1] == '\\':
    # Check if the regex contains an invalid trailing backslash.
    let j = buf.countBackslashes(buf.high - 1)
    if j mod 2 != 1: # odd, because we do not count the last backslash
      return err("unexpected end")
  var buf2 = "^"
  buf2 &= buf
  buf2 &= "$"
  return compileRegex(buf2, 0)

proc compileSearchRegex*(str: string): Result[Regex, string] =
  # Parse any applicable flags in regex/<flags>. The last forward slash is
  # dropped when <flags> is empty, and interpreted as a character when the
  # flags are is invalid.

  var i = str.high
  var flagsi = -1
  while i >= 0:
    case str[i]
    of '/':
      flagsi = i
      break
    of 'i', 'm', 's', 'u': discard
    else: break # invalid flag
    dec i

  var flags = LRE_FLAG_GLOBAL # for easy backwards matching

  if flagsi == -1:
    return compileRegex(str, flags)

  for i in flagsi..str.high:
    case str[i]
    of '/': discard
    of 'i': flags = flags or LRE_FLAG_IGNORECASE
    of 'm': flags = flags or LRE_FLAG_MULTILINE
    of 's': flags = flags or LRE_FLAG_DOTALL
    of 'u': flags = flags or LRE_FLAG_UTF16
    else: assert false
  return compileRegex(str.substr(0, flagsi - 1), flags)

proc exec*(regex: Regex, str: string, start = 0, length = -1, nocaps = false): RegexResult =
  let length = if length == -1:
    str.len
  else:
    length
  assert 0 <= start and start <= length, "Start: " & $start & ", length: " & $length & " str: " & $str

  let captureCount = lre_get_capture_count(regex.bytecode)
  var capture: ptr UncheckedArray[int] = nil
  if captureCount > 0:
    let size = sizeof(ptr uint8) * captureCount * 2
    capture = cast[ptr UncheckedArray[int]](alloc0(size))
  var cstr = cstring(str)
  let flags = lre_get_flags(regex.bytecode)
  var start = start
  while true:
    let ret = lre_exec(cast[ptr ptr uint8](capture), regex.bytecode,
      cast[ptr uint8](cstr), cint(start), cint(length), cint(0), dummyContext)
    if ret != 1: #TODO error handling? (-1)
      break
    result.success = true
    if captureCount == 0 or nocaps:
      break
    let cstrAddress = cast[int](cstr)
    let ps = start
    start = capture[1] - cstrAddress
    for i in 0 ..< captureCount:
      let s = capture[i * 2] - cstrAddress
      let e = capture[i * 2 + 1] - cstrAddress
      result.captures.add((s, e))
    if (flags and LRE_FLAG_GLOBAL) != 1:
      break
    if start >= str.len:
      break
    if ps == start:
      start += runeLenAt(str, start)
  if captureCount > 0:
    dealloc(capture)

proc match*(regex: Regex, str: string, start = 0, length = str.len): bool =
  return regex.exec(str, start, length, nocaps = true).success

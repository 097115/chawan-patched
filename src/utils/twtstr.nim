import std/algorithm
import std/math
import std/options
import std/os
import std/posix
import std/strutils

import types/opt
import utils/map

const C0Controls* = {'\0'..'\x1F'}
const Controls* = C0Controls + {'\x7F'}
const Ascii* = {'\0'..'\x7F'}
const AsciiUpperAlpha* = {'A'..'Z'}
const AsciiLowerAlpha* = {'a'..'z'}
const AsciiAlpha* = AsciiUpperAlpha + AsciiLowerAlpha
const NonAscii* = {'\x80'..'\xFF'}
const AsciiDigit* = {'0'..'9'}
const AsciiAlphaNumeric* = AsciiAlpha + AsciiDigit
const AsciiHexDigit* = AsciiDigit + {'a'..'f', 'A'..'F'}
const AsciiWhitespace* = {' ', '\n', '\r', '\t', '\f'}
const HTTPWhitespace* = {' ', '\n', '\r', '\t'}

func nextUTF8*(s: openArray[char]; i: var int): uint32 =
  let j = i
  let u = uint32(s[j])
  if u <= 0x7F:
    inc i
    return u
  elif u shr 5 == 0b110:
    let e = j + 2
    if likely(e <= s.len):
      i = e
      return (u and 0x1F) shl 6 or
        (uint32(s[j + 1]) and 0x3F)
  elif u shr 4 == 0b1110:
    let e = j + 3
    if likely(e <= s.len):
      i = e
      return (u and 0xF) shl 12 or
        (uint32(s[j + 1]) and 0x3F) shl 6 or
        (uint32(s[j + 2]) and 0x3F)
  elif u shr 3 == 0b11110:
    let e = j + 4
    if likely(e <= s.len):
      i = e
      return (u and 7) shl 18 or
        (uint32(s[j + 1]) and 0x3F) shl 12 or
        (uint32(s[j + 2]) and 0x3F) shl 6 or
        (uint32(s[j + 3]) and 0x3F)
  inc i
  return 0xFFFD

func prevUTF8*(s: openArray[char]; i: var int): uint32 =
  var j = i - 1
  while uint32(s[j]) shr 6 == 2:
    dec j
  i = j
  return s.nextUTF8(j)

func pointLenAt*(s: openArray[char]; i: int): int =
  let u = uint8(s[i])
  if u <= 0x7F:
    return 1
  elif u shr 5 == 0b110:
    return 2
  elif u shr 4 == 0b1110:
    return 3
  elif u shr 3 == 0b11110:
    return 4
  return 1

iterator points*(s: openArray[char]): uint32 {.inline.} =
  var i = 0
  while i < s.len:
    let u = s.nextUTF8(i)
    yield u

func toPoints*(s: openArray[char]): seq[uint32] =
  result = @[]
  for u in s.points:
    result.add(u)

proc addUTF8*(res: var string; u: uint32) =
  if u < 0x80:
    res &= char(u)
  elif u < 0x800:
    res &= char(u shr 6 or 0xC0)
    res &= char(u and 0x3F or 0x80)
  elif u < 0x10000:
    res &= char(u shr 12 or 0xE0)
    res &= char(u shr 6 and 0x3F or 0x80)
    res &= char(u and 0x3F or 0x80)
  else:
    res &= char(u shr 18 or 0xF0)
    res &= char(u shr 12 and 0x3F or 0x80)
    res &= char(u shr 6 and 0x3F or 0x80)
    res &= char(u and 0x3F or 0x80)

func addUTF8*(res: var string; us: openArray[uint32]) =
  for u in us:
    res.addUTF8(u)

func toUTF8*(u: uint32): string =
  result = ""
  result.addUTF8(u)

func toUTF8*(us: openArray[uint32]): string =
  result = newStringOfCap(us.len)
  result.addUTF8(us)

func pointLen*(s: openArray[char]): int =
  var n = 0
  for u in s.points:
    inc n
  return n

func onlyWhitespace*(s: string): bool =
  return AllChars - AsciiWhitespace notin s

func isControlChar*(u: uint32): bool =
  return u <= 0x1F or u >= 0x7F and u <= 0x9F

func getControlChar*(c: char): char =
  if c == '?':
    return '\x7F'
  return char(int(c) and 0x1F)

func toHeaderCase*(s: string): string =
  result = newStringOfCap(s.len)
  var flip = true
  for c in s:
    if flip:
      result &= c.toUpperAscii()
    else:
      result &= c.toLowerAscii()
    flip = c == '-'

func kebabToCamelCase*(s: string): string =
  result = ""
  var flip = false
  for c in s:
    if c == '-':
      flip = true
    else:
      if flip:
        result &= c.toUpperAscii()
      else:
        result &= c
      flip = false

func camelToKebabCase*(s: openArray[char]; dashPrefix = false): string =
  result = newStringOfCap(s.len)
  if dashPrefix:
    result &= '-'
  for c in s:
    if c in AsciiUpperAlpha:
      result &= '-'
      result &= c.toLowerAscii()
    else:
      result &= c

func hexValue*(c: char): int =
  if c in AsciiDigit:
    return int(c) - int('0')
  if c in 'a'..'f':
    return int(c) - int('a') + 0xA
  if c in 'A'..'F':
    return int(c) - int('A') + 0xA
  return -1

func decValue*(c: char): int =
  if c in AsciiDigit:
    return int(c) - int('0')
  return -1

const HexCharsUpper = "0123456789ABCDEF"
const HexCharsLower = "0123456789abcdef"
func pushHex*(buf: var string; u: uint8) =
  buf &= HexCharsUpper[u shr 4]
  buf &= HexCharsUpper[u and 0xF]

func pushHex*(buf: var string; c: char) =
  buf.pushHex(uint8(c))

func toHexLower*(u: uint16): string =
  var x = u
  let len = if (u and 0xF000) != 0:
    4
  elif (u and 0x0F00) != 0:
    3
  elif (u and 0xF0) != 0:
    2
  else:
    1
  var s = newString(len)
  for i in countdown(len - 1, 0):
    s[i] = HexCharsLower[x and 0xF]
    x = x shr 4
  return move(s)

func controlToVisual*(u: uint32): string =
  if u <= 0x1F:
    return "^" & char(u or 0x40)
  if u == 0x7F:
    return "^?"
  var res = "["
  res.pushHex(uint8(u))
  res &= ']'
  return move(res)

proc add*(s: var string; u: uint8) =
  s.addInt(uint64(u))

func equalsIgnoreCase*(s1, s2: string): bool {.inline.} =
  return s1.cmpIgnoreCase(s2) == 0

func startsWithIgnoreCase*(s1, s2: openArray[char]): bool =
  if s1.len < s2.len:
    return false
  for i in 0 ..< s2.len:
    if s1[i].toLowerAscii() != s2[i].toLowerAscii():
      return false
  return true

func endsWithIgnoreCase*(s1, s2: openArray[char]): bool =
  if s1.len < s2.len:
    return false
  let h1 = s1.high
  let h2 = s2.high
  for i in 0 ..< s2.len:
    if s1[h1 - i].toLowerAscii() != s2[h2 - i].toLowerAscii():
      return false
  return true

func skipBlanks*(buf: openArray[char]; at: int): int =
  result = at
  while result < buf.len and buf[result] in AsciiWhitespace:
    inc result

func skipBlanksTillLF*(buf: openArray[char]; at: int): int =
  result = at
  while result < buf.len and buf[result] in AsciiWhitespace - {'\n'}:
    inc result

func stripAndCollapse*(s: openArray[char]): string =
  var res = newStringOfCap(s.len)
  var space = false
  for c in s.toOpenArray(s.skipBlanks(0), s.high):
    let cspace = c in AsciiWhitespace
    if not cspace:
      if space:
        res &= ' '
      res &= c
    space = cspace
  return move(res)

func until*(s: openArray[char]; c: set[char]; starti = 0): string =
  result = ""
  for i in starti ..< s.len:
    if s[i] in c:
      break
    result &= s[i]

func untilLower*(s: openArray[char]; c: set[char]; starti = 0): string =
  result = ""
  for i in starti ..< s.len:
    if s[i] in c:
      break
    result.add(s[i].toLowerAscii())

func until*(s: openArray[char]; c: char; starti = 0): string =
  return s.until({c}, starti)

func untilLower*(s: openArray[char]; c: char; starti = 0): string =
  return s.untilLower({c}, starti)

func after*(s: string; c: set[char]): string =
  let i = s.find(c)
  if i != -1:
    return s.substr(i + 1)
  return ""

func after*(s: string; c: char): string = s.after({c})

func afterLast*(s: string; c: set[char]; n = 1): string =
  var j = 0
  for i in countdown(s.high, 0):
    if s[i] in c:
      inc j
      if j == n:
        return s.substr(i + 1)
  return s

func afterLast*(s: string; c: char; n = 1): string = s.afterLast({c}, n)

func untilLast*(s: string; c: set[char]; n = 1): string =
  var j = 0
  for i in countdown(s.high, 0):
    if s[i] in c:
      inc j
      if j == n:
        return s.substr(0, i)
  return s

func untilLast*(s: string; c: char; n = 1): string = s.untilLast({c}, n)

proc snprintf(str: cstring; size: csize_t; format: cstring): cint
  {.header: "<stdio.h>", importc, varargs}

# From w3m
const SizeUnit = [
  cstring"b", cstring"kb", cstring"Mb", cstring"Gb", cstring"Tb", cstring"Pb",
  cstring"Eb", cstring"Zb", cstring"Bb", cstring"Yb"
]
func convertSize*(size: int): string =
  var sizepos = 0
  var csize = float32(size)
  while csize >= 999.495 and sizepos < SizeUnit.len:
    csize = csize / 1024.0
    inc sizepos
  result = newString(10)
  let f = floor(csize * 100 + 0.5) / 100
  discard snprintf(cstring(result), csize_t(result.len), "%.3g%s", f,
    SizeUnit[sizepos])
  result.setLen(cstring(result).len)

# https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#numbers
func parseUIntImpl[T: SomeUnsignedInt](s: openArray[char]; allowSign: bool;
    radix: T): Option[T] =
  var i = 0
  if i < s.len and allowSign and s[i] == '+':
    inc i
  var fail = i == s.len # fail on empty input
  var integer: T = 0
  for i in i ..< s.len:
    let u = T(hexValue(s[i]))
    let n = integer * radix + u
    fail = fail or u >= radix or n < integer # overflow check
    integer = n
  if fail:
    return none(T) # invalid or overflow
  return some(integer)

func parseUInt8*(s: openArray[char]; allowSign = false): Option[uint8] =
  return parseUIntImpl[uint8](s, allowSign, 10)

func parseUInt16*(s: openArray[char]; allowSign = false): Option[uint16] =
  return parseUIntImpl[uint16](s, allowSign, 10)

func parseUInt32Base*(s: openArray[char]; allowSign = false; radix: uint32):
    Option[uint32] =
  return parseUIntImpl[uint32](s, allowSign, radix)

func parseUInt32*(s: openArray[char]; allowSign = false): Option[uint32] =
  return parseUInt32Base(s, allowSign, 10)

func parseUInt64*(s: openArray[char]; allowSign = false): Option[uint64] =
  return parseUIntImpl[uint64](s, allowSign, 10)

func parseIntImpl[T: SomeSignedInt; U: SomeUnsignedInt](s: openArray[char];
    radix: U): Option[T] =
  var sign: T = 1
  var i = 0
  if s.len > 0 and s[0] == '-':
    sign = -1
    inc i
  let res = parseUIntImpl[U](s.toOpenArray(i, s.high), allowSign = true, radix)
  let u = res.get(U.high)
  if sign == -1 and u == U(T.high) + 1:
    return some(T.low) # negative has one more valid int
  if u <= U(T.high):
    return some(T(u) * sign)
  return none(T)

func parseInt32*(s: openArray[char]): Option[int32] =
  return parseIntImpl[int32, uint32](s, 10)

func parseInt64*(s: openArray[char]): Option[int64] =
  return parseIntImpl[int64, uint64](s, 10)

func parseOctInt64*(s: openArray[char]): Option[int64] =
  return parseIntImpl[int64, uint64](s, 8)

func parseHexInt64*(s: openArray[char]): Option[int64] =
  return parseIntImpl[int64, uint64](s, 16)

func parseIntP*(s: openArray[char]): Option[int] =
  return parseIntImpl[int, uint](s, 10)

# https://www.w3.org/TR/css-syntax-3/#convert-string-to-number
func parseFloat32*(s: openArray[char]): float32 =
  var sign = 1f64
  var t = 1
  var d = 0
  var integer = 0f32
  var f = 0f32
  var e = 0f32
  var i = 0
  if i < s.len and s[i] == '-':
    sign = -1f64
    inc i
  elif i < s.len and s[i] == '+':
    inc i
  while i < s.len and s[i] in AsciiDigit:
    integer *= 10
    integer += float32(decValue(s[i]))
    inc i
  if i < s.len and s[i] == '.':
    inc i
    while i < s.len and s[i] in AsciiDigit:
      f *= 10
      f += float32(decValue(s[i]))
      inc i
      inc d
  if i < s.len and (s[i] == 'e' or s[i] == 'E'):
    inc i
    if i < s.len and s[i] == '-':
      t = -1
      inc i
    elif i < s.len and s[i] == '+':
      inc i
    while i < s.len and s[i] in AsciiDigit:
      e *= 10
      e += float32(decValue(s[i]))
      inc i
  return sign * (integer + f * pow(10, float32(-d))) * pow(10, (float32(t) * e))

const ControlPercentEncodeSet* = Controls + NonAscii
const FragmentPercentEncodeSet* = ControlPercentEncodeSet +
  {' ', '"', '<', '>', '`'}
const QueryPercentEncodeSet* = FragmentPercentEncodeSet - {'`'} + {'#'}
const SpecialQueryPercentEncodeSet* = QueryPercentEncodeSet + {'\''}
const PathPercentEncodeSet* = QueryPercentEncodeSet + {'?', '`', '{', '}'}
const UserInfoPercentEncodeSet* = PathPercentEncodeSet +
  {'/', ':', ';', '=', '@', '['..'^', '|'}
const ComponentPercentEncodeSet* = UserInfoPercentEncodeSet +
  {'$'..'&', '+', ','}
const ApplicationXWWWFormUrlEncodedSet* = ComponentPercentEncodeSet +
  {'!', '\''..')', '~'}
# used by pager
when DirSep == '\\':
  const LocalPathPercentEncodeSet* = Ascii - AsciiAlpha - AsciiDigit -
    {'.', '\\', '/'}
else:
  const LocalPathPercentEncodeSet* = Ascii - AsciiAlpha - AsciiDigit -
    {'.', '/'}

proc percentEncode*(append: var string; c: char; set: set[char];
    spaceAsPlus = false) {.inline.} =
  if spaceAsPlus and c == ' ':
    append &= '+'
  elif c notin set:
    append &= c
  else:
    append &= '%'
    append.pushHex(c)

proc percentEncode*(append: var string; s: openArray[char]; set: set[char];
    spaceAsPlus = false) =
  for c in s:
    append.percentEncode(c, set, spaceAsPlus)

func percentEncode*(s: openArray[char]; set: set[char]; spaceAsPlus = false):
    string =
  result = ""
  result.percentEncode(s, set, spaceAsPlus)

func percentDecode*(input: openArray[char]): string =
  result = ""
  var i = 0
  while i < input.len:
    let c = input[i]
    if c != '%' or i + 2 >= input.len:
      result &= c
    else:
      let h1 = input[i + 1].hexValue
      let h2 = input[i + 2].hexValue
      if h1 == -1 or h2 == -1:
        result &= c
      else:
        result &= char((h1 shl 4) or h2)
        i += 2
    inc i

func htmlEscape*(s: openArray[char]): string =
  result = ""
  for c in s:
    case c
    of '<': result &= "&lt;"
    of '>': result &= "&gt;"
    of '&': result &= "&amp;"
    of '"': result &= "&quot;"
    of '\'': result &= "&apos;"
    else: result &= c

func dqEscape*(s: openArray[char]): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c == '"':
      result &= '\\'
    result &= c

func cssEscape*(s: openArray[char]): string =
  result = ""
  for c in s:
    if c == '\'':
      result &= '\\'
    result &= c

#basically std join but with char
func join*(ss: openArray[string]; sep: char): string =
  if ss.len == 0:
    return ""
  result = ss[0]
  for i in 1 ..< ss.len:
    result &= sep
    result &= ss[i]

# https://www.w3.org/TR/xml/#NT-Name
const NameStartCharRanges = [
  (0xC0u32, 0xD6u32),
  (0xD8u32, 0xF6u32),
  (0xF8u32, 0x2FFu32),
  (0x370u32, 0x37Du32),
  (0x37Fu32, 0x1FFFu32),
  (0x200Cu32, 0x200Du32),
  (0x2070u32, 0x218Fu32),
  (0x2C00u32, 0x2FEFu32),
  (0x3001u32, 0xD7FFu32),
  (0xF900u32, 0xFDCFu32),
  (0xFDF0u32, 0xFFFDu32),
  (0x10000u32, 0xEFFFFu32)
]
const NameCharRanges = [ # + NameStartCharRanges
  (0xB7u32, 0xB7u32),
  (0x0300u32, 0x036Fu32),
  (0x203Fu32, 0x2040u32)
]
const NameStartCharAscii = {':', '_'} + AsciiAlpha
const NameCharAscii = NameStartCharAscii + {'-', '.'} + AsciiDigit
func matchNameProduction*(s: openArray[char]): bool =
  if s.len == 0:
    return false
  # NameStartChar
  var i = 0
  if s[i] in Ascii:
    if s[i] notin NameStartCharAscii:
      return false
    inc i
  else:
    let u = s.nextUTF8(i)
    if not NameStartCharRanges.isInRange(u):
      return false
  # NameChar
  while i < s.len:
    if s[i] in Ascii:
      if s[i] notin NameCharAscii:
        return false
      inc i
    else:
      let u = s.nextUTF8(i)
      if not NameStartCharRanges.isInRange(u) and not NameCharRanges.isInMap(u):
        return false
  return true

func matchQNameProduction*(s: openArray[char]): bool =
  if s.len == 0:
    return false
  if s[0] == ':':
    return false
  if s[^1] == ':':
    return false
  var colon = false
  for i in 1 ..< s.len - 1:
    if s[i] == ':':
      if colon:
        return false
      colon = true
  return s.matchNameProduction()

func utf16Len*(s: openArray[char]): int =
  result = 0
  for u in s.points:
    if u < 0x10000: # ucs-2
      result += 1
    else: # surrogate
      result += 2

proc expandPath*(path: string): string =
  if path.len > 0 and path[0] == '~':
    if path.len == 1:
      return getHomeDir()
    if path[1] == '/':
      return getHomeDir() / path.substr(2)
    let usr = path.until({'/'}, 1)
    let p = getpwnam(cstring(usr))
    if p != nil and p.pw_dir != nil:
      return $p.pw_dir / path.substr(usr.len)
  return path

func deleteChars*(s: openArray[char]; todel: set[char]): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c notin todel:
      result &= c

func replaceControls*(s: openArray[char]): string =
  result = newStringOfCap(s.len)
  for u in s.points:
    if u.isControlChar():
      result &= u.controlToVisual()
    else:
      result.addUTF8(u)

#https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#multipart/form-data-encoding-algorithm
proc makeCRLF*(s: openArray[char]): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len - 1:
    if s[i] == '\r' and s[i + 1] != '\n':
      result &= '\r'
      result &= '\n'
    elif s[i] != '\r' and s[i + 1] == '\n':
      result &= s[i]
      result &= '\r'
      result &= '\n'
      inc i
    else:
      result &= s[i]
    inc i
  if i < s.len:
    if s[i] == '\r':
      result &= '\r'
      result &= '\n'
    else:
      result &= s[i]

type IdentMapItem* = tuple[s: string; n: int]

func getIdentMap*[T: enum](e: typedesc[T]): seq[IdentMapItem] =
  result = @[]
  for e in T.low .. T.high:
    result.add(($e, int(e)))
  result.sort(proc(x, y: IdentMapItem): int = cmp(x.s, y.s))

func cmpItem(x: IdentMapItem; y: string): int =
  return x.s.cmp(y)

func strictParseEnum0(map: openArray[IdentMapItem]; s: string): int =
  let i = map.binarySearch(s, cmpItem)
  if i != -1:
    return map[i].n
  return -1

func strictParseEnum*[T: enum](s: string): Option[T] =
  const IdentMap = getIdentMap(T)
  let n = IdentMap.strictParseEnum0(s)
  if n != -1:
    return some(T(n))
  return none(T)

func parseEnumNoCase0*(map: openArray[IdentMapItem]; s: string): int =
  let i = map.binarySearch(s, proc(x: IdentMapItem; y: string): int =
    return x[0].cmpIgnoreCase(y)
  )
  if i != -1:
    return map[i].n
  return -1

func parseEnumNoCase*[T: enum](s: string): Opt[T] =
  const IdentMap = getIdentMap(T)
  let n = IdentMap.parseEnumNoCase0(s)
  if n != -1:
    return ok(T(n))
  return err()

const tchar = AsciiAlphaNumeric +
  {'!', '#'..'\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'}

proc getContentTypeAttr*(contentType, attrname: string): string =
  var i = contentType.find(';')
  if i == -1:
    return ""
  i = contentType.find(attrname, i)
  if i == -1:
    return ""
  i = contentType.skipBlanks(i + attrname.len)
  if i >= contentType.len or contentType[i] != '=':
    return ""
  i = contentType.skipBlanks(i + 1)
  if i >= contentType.len:
    return ""
  var q = false
  result = ""
  let dq = contentType[i] == '"'
  if dq:
    inc i
  for c in contentType.toOpenArray(i, contentType.high):
    if q:
      result &= c
      q = false
    elif dq and c == '"':
      break
    elif c == '\\':
      q = true
    elif not dq and c notin tchar:
      break
    else:
      result &= c

# turn value into quoted-string
proc mimeQuote*(value: string): string =
  var s = newStringOfCap(value.len)
  s &= '"'
  var found = false
  for c in value:
    if c notin tchar:
      s &= '\\'
      found = true
    s &= c
  if not found:
    return value
  s &= '"'
  return move(s)

proc setContentTypeAttr*(contentType: var string; attrname, value: string) =
  var i = contentType.find(';')
  if i == -1:
    contentType &= ';' & attrname & '=' & value
    return
  i = contentType.find(attrname, i)
  if i == -1:
    contentType &= ';' & attrname & '=' & value
    return
  i = contentType.skipBlanks(i + attrname.len)
  if i >= contentType.len or contentType[i] != '=':
    contentType &= ';' & attrname & '=' & value
    return
  i = contentType.skipBlanks(i + 1)
  var q = false
  var j = i
  while j < contentType.len:
    let c = contentType[j]
    if q:
      q = false
    elif c == '\\':
      q = true
    elif c notin tchar:
      break
    inc j
  contentType[i..<j] = value.mimeQuote()

func atob(c: char): uint8 {.inline.} =
  # see RFC 4648 table
  if c in AsciiUpperAlpha:
    return uint8(c) - uint8('A')
  if c in AsciiLowerAlpha:
    return uint8(c) - uint8('a') + 26
  if c in AsciiDigit:
    return uint8(c) - uint8('0') + 52
  if c == '+':
    return 62
  if c == '/':
    return 63
  return uint8.high

# Warning: this overrides outs.
func atob*(outs: out string; data: string): Err[cstring] =
  outs = newStringOfCap(data.len div 4 * 3)
  var buf = array[4, uint8].default
  var i = 0
  var j = 0
  var pad = 0
  while true:
    i = data.skipBlanks(i)
    if i >= data.len:
      break
    if data[i] == '=':
      i = data.skipBlanks(i + 1)
      inc pad
      break
    buf[j] = atob(data[i])
    if buf[j] == uint8.high:
      return err("Invalid character in encoded string")
    if j == 3:
      let ob1 = (buf[0] shl 2) or (buf[1] shr 4) # 6 bits of b0 | 2 bits of b1
      let ob2 = (buf[1] shl 4) or (buf[2] shr 2) # 4 bits of b1 | 4 bits of b2
      let ob3 = (buf[2] shl 6) or buf[3]         # 2 bits of b2 | 6 bits of b3
      outs &= char(ob1)
      outs &= char(ob2)
      outs &= char(ob3)
      j = 0
    else:
      inc j
    inc i
  if i < data.len:
    if i < data.len and data[i] == '=':
      inc pad
      inc i
    i = data.skipBlanks(i)
  if pad > 0 and j + pad != 4:
    return err("Too much padding")
  if i < data.len:
    return err("Invalid character after encoded string")
  if j == 3:
    let ob1 = (buf[0] shl 2) or (buf[1] shr 4) # 6 bits of b0 | 2 bits of b1
    let ob2 = (buf[1] shl 4) or (buf[2] shr 2) # 4 bits of b1 | 4 bits of b2
    outs &= char(ob1)
    outs &= char(ob2)
  elif j == 2:
    let ob1 = (buf[0] shl 2) or (buf[1] shr 4) # 6 bits of b0 | 2 bits of b1
    outs &= char(ob1)
  elif j != 0:
    return err("Incorrect number of characters in encoded string")
  return ok()

const AMap = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

func btoa*(s: var string; data: openArray[uint8]) =
  var i = 0
  let endw = data.len - 2
  while i < endw:
    let n = uint32(data[i]) shl 16 or
      uint32(data[i + 1]) shl 8 or
      uint32(data[i + 2])
    i += 3
    s &= AMap[n shr 18 and 0x3F]
    s &= AMap[n shr 12 and 0x3F]
    s &= AMap[n shr 6 and 0x3F]
    s &= AMap[n and 0x3F]
  if i < data.len:
    let b1 = uint32(data[i])
    inc i
    if i < data.len:
      let b2 = uint32(data[i])
      s &= AMap[b1 shr 2]                      # 6 bits of b1
      s &= AMap[b1 shl 4 and 0x3F or b2 shr 4] # 2 bits of b1 | 4 bits of b2
      s &= AMap[b2 shl 2 and 0x3F]             # 4 bits of b2
    else:
      s &= AMap[b1 shr 2]          # 6 bits of b1
      s &= AMap[b1 shl 4 and 0x3F] # 2 bits of b1
      s &= '='
    s &= '='

func btoa*(data: openArray[uint8]): string =
  if data.len == 0:
    return ""
  var L = data.len div 3 * 4
  if (let rem = data.len mod 3; rem) > 0:
    L += 3 - rem
  var s = newStringOfCap(L)
  s.btoa(data)
  return move(s)

func btoa*(data: openArray[char]): string =
  return btoa(data.toOpenArrayByte(0, data.len - 1))

proc getEnvEmpty*(name: string; fallback = ""): string =
  let res = getEnv(name, fallback)
  if res != "":
    return res
  return fallback

iterator mypairs*[T](a: openArray[T]): tuple[key: int; val: lent T] {.inline.} =
  var i = 0
  let L = a.len
  while i < L:
    yield (i, a[i])
    {.push overflowChecks: off.}
    inc i
    {.pop.}

proc getFileExt*(path: string): string =
  let n = path.rfind({'/', '.'})
  if n == -1 or path[n] != '.':
    return ""
  return path.substr(n + 1)

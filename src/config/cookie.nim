import std/algorithm
import std/options
import std/posix
import std/strutils
import std/tables
import std/times

import io/dynstream
import types/opt
import types/url
import utils/twtstr

type
  Cookie* = ref object
    name: string
    value: string
    expires: int64 # unix time
    domain: string
    path: string
    persist: bool
    secure: bool
    httpOnly: bool
    hostOnly: bool
    isnew: bool
    skip: bool

  CookieJar* = ref object
    cookies*: seq[Cookie]
    map: Table[string, Cookie] # {host}{path}\t{name}

  CookieJarMap* = ref object
    mtime: int64
    jars*: OrderedTable[string, CookieJar]

proc newCookieJarMap*(): CookieJarMap =
  return CookieJarMap()

proc newCookieJar*(): CookieJar =
  return CookieJar()

proc parseCookieDate(val: string): Option[int64] =
  # cookie-date
  const Delimiters = {'\t', ' '..'/', ';'..'@', '['..'`', '{'..'~'}
  const NonDigit = AllChars - AsciiDigit
  var foundTime = false
  # date-token-list
  var time = array[3, int].default
  var dayOfMonth = 0
  var month = 0
  var year = -1
  for dateToken in val.split(Delimiters):
    if dateToken == "": continue # *delimiter
    if not foundTime: # test for time
      let hmsTime = dateToken.until(NonDigit - {':'})
      var i = 0
      for timeField in hmsTime.split(':'):
        if i > 2:
          i = 0
          break # too many time fields
        # 1*2DIGIT
        if timeField.len != 1 and timeField.len != 2:
          i = 0
          break
        time[i] = parseInt32(timeField).get
        inc i
      if i == 3:
        foundTime = true
        continue
    if dayOfMonth == 0: # test for day-of-month
      let digits = dateToken.until(NonDigit)
      if digits.len in 1..2:
        dayOfMonth = parseInt32(digits).get
        continue
    if month == 0: # test for month
      if dateToken.len >= 3:
        case dateToken.substr(0, 2).toLowerAscii()
        of "jan": month = 1
        of "feb": month = 2
        of "mar": month = 3
        of "apr": month = 4
        of "may": month = 5
        of "jun": month = 6
        of "jul": month = 7
        of "aug": month = 8
        of "sep": month = 9
        of "oct": month = 10
        of "nov": month = 11
        of "dec": month = 12
        else: discard
        if month != 0:
          continue
    if year == -1: # test for year
      let digits = dateToken.until(NonDigit)
      if digits.len == 4:
        year = parseInt32(digits).get
        continue
  if not (month != 0 and dayOfMonth in 1..getDaysInMonth(Month(month), year) and
      year >= 1601 and foundTime):
    return none(int64)
  if time[0] > 23: return none(int64)
  if time[1] > 59: return none(int64)
  if time[2] > 59: return none(int64)
  let dt = dateTime(year, Month(month), MonthdayRange(dayOfMonth),
    HourRange(time[0]), MinuteRange(time[1]), SecondRange(time[2]),
    zone = utc())
  return some(dt.toTime().toUnix())

# For debugging
proc `$`*(cookieJar: CookieJar): string =
  result = ""
  for cookie in cookieJar.cookies:
    result &= "Cookie "
    result &= $cookie[]
    result &= "\n"

# https://www.rfc-editor.org/rfc/rfc6265#section-5.1.4
func defaultCookiePath(url: URL): string =
  var path = url.pathname.untilLast('/')
  if path == "" or path[0] != '/':
    return "/"
  return move(path)

func cookiePathMatches(cookiePath, requestPath: string): bool =
  if requestPath.startsWith(cookiePath):
    if requestPath.len == cookiePath.len:
      return true
    if cookiePath[^1] == '/':
      return true
    if requestPath.len > cookiePath.len and requestPath[cookiePath.len] == '/':
      return true
  return false

func cookieDomainMatches(cookieDomain: string; url: URL): bool =
  if cookieDomain.len == 0:
    return false
  let host = url.host
  if url.isIP():
    return host == cookieDomain
  if host.endsWith(cookieDomain) and host.len >= cookieDomain.len:
    return host.len == cookieDomain.len or
      host[host.len - cookieDomain.len - 1] == '.'
  return false

proc add(cookieJar: CookieJar; cookie: Cookie; parseMode = false,
    persist = true) =
  let s = cookie.domain & cookie.path & '\t' & cookie.name
  let old = cookieJar.map.getOrDefault(s)
  if old != nil:
    if parseMode and old.isnew:
      return # do not override newly added cookies
    if persist or not old.persist:
      let i = cookieJar.cookies.find(old)
      cookieJar.cookies.delete(i)
    else:
      # we cannot save this cookie, but it must be kept for this session.
      old.skip = true
  cookieJar.map[s] = cookie
  cookieJar.cookies.add(cookie)

# https://www.rfc-editor.org/rfc/rfc6265#section-5.4
proc serialize*(cookieJar: CookieJar; url: URL): string =
  var res = ""
  let t = getTime().toUnix()
  var expired: seq[int] = @[]
  for i, cookie in cookieJar.cookies.mypairs:
    let cookie = cookieJar.cookies[i]
    if cookie.skip: # "read-only" cookie
      continue
    if cookie.expires != -1 and cookie.expires <= t:
      expired.add(i)
      continue
    if cookie.secure and url.scheme != "https":
      continue
    if not cookiePathMatches(cookie.path, url.pathname):
      continue
    if cookie.hostOnly and cookie.domain != url.host:
      continue
    if not cookie.hostOnly and not cookieDomainMatches(cookie.domain, url):
      continue
    if res != "":
      res &= "; "
    res &= cookie.name
    res &= "="
    res &= cookie.value
  for j in countdown(expired.high, 0):
    cookieJar.cookies.delete(expired[j])
  return move(res)

proc parseSetCookie(str: string; t: int64; url: URL; persist: bool):
    Opt[Cookie] =
  let cookie = Cookie(
    expires: -1,
    hostOnly: true,
    persist: persist,
    isnew: true
  )
  var first = true
  var hasPath = false
  for part in str.split(';'):
    if first:
      if '\t' in part:
        # Drop cookie if it has a tab.
        # Gecko seems to accept it, but Blink drops it too,
        # so this should be safe from a compat perspective.
        continue
      cookie.name = part.until('=')
      cookie.value = part.substr(cookie.name.len + 1)
      first = false
      continue
    let part = part.strip(leading = true, trailing = false, AsciiWhitespace)
    let key = part.untilLower('=')
    let val = part.substr(key.len + 1)
    case key
    of "expires":
      if cookie.expires == -1:
        let date = parseCookieDate(val)
        if date.isSome:
          cookie.expires = date.get
    of "max-age":
      let x = parseInt32(val)
      if x.get(-1) >= 0:
        cookie.expires = t + x.get
    of "secure": cookie.secure = true
    of "httponly": cookie.httpOnly = true
    of "path":
      if val != "" and val[0] == '/' and '\t' notin val:
        hasPath = true
        cookie.path = val
    of "domain":
      var hostType = htNone
      var domain = parseHost(val, special = false, hostType)
      if domain.len > 0 and domain[0] == '.':
        domain.delete(0..0)
      if hostType == htNone or not cookieDomainMatches(domain, url):
        return err()
      if hostType != htNone:
        cookie.domain = move(domain)
        cookie.hostOnly = false
  if cookie.hostOnly:
    cookie.domain = url.host
  if not hasPath:
    cookie.path = defaultCookiePath(url)
  if cookie.expires < 0:
    cookie.persist = false
  return ok(cookie)

proc setCookie*(cookieJar: CookieJar; header: openArray[string]; url: URL;
    persist: bool) =
  let t = getTime().toUnix()
  var sorted = true
  for s in header:
    let cookie = parseSetCookie(s, t, url, persist)
    if cookie.isSome:
      cookieJar.add(cookie.get, persist = persist)
      sorted = false
  if not sorted:
    cookieJar.cookies.sort(proc(a, b: Cookie): int =
      return cmp(a.path.len, b.path.len), order = Descending)

type ParseState = object
  i: int
  cookie: Cookie
  error: bool

proc nextField(state: var ParseState; iq: openArray[char]): string =
  if state.i >= iq.len or iq[state.i] == '\n':
    state.error = true
    return ""
  var field = iq.until({'\t', '\n'}, state.i)
  state.i += field.len
  if state.i < iq.len and iq[state.i] == '\t':
    inc state.i
  return move(field)

proc nextBool(state: var ParseState; iq: openArray[char]): bool =
  let field = state.nextField(iq)
  if field == "TRUE":
    return true
  if field != "FALSE":
    state.error = true
  return false

proc nextInt64(state: var ParseState; iq: openArray[char]): int64 =
  let x = parseInt64(state.nextField(iq))
  if x.isNone:
    state.error = true
    return 0
  return x.get

proc parse(map: CookieJarMap; iq: openArray[char]; warnings: var seq[string]) =
  var state = ParseState()
  var line = 0
  while state.i < iq.len:
    var httpOnly = false
    if iq[state.i] == '\n':
      inc state.i
      continue
    if iq[state.i] == '#':
      inc state.i
      let first = iq.until({'_', '\n'}, state.i)
      state.i += first.len
      if first != "HttpOnly":
        while state.i < iq.len and iq[state.i] != '\n':
          inc state.i
        inc state.i
        inc line
        continue
      inc state.i
      httpOnly = true
    state.error = false
    let cookie = Cookie(httpOnly: httpOnly, persist: true)
    var domain = state.nextField(iq)
    var cookieJar: CookieJar = nil
    if (let j = domain.find('@'); j != -1):
      cookie.domain = domain.substr(j + 1)
      if cookie.domain[0] == '.':
        cookie.domain.delete(0..0)
      domain.setLen(j)
    else:
      if domain[0] == '.':
        domain.delete(0..0)
      cookie.domain = domain
    cookieJar = map.jars.getOrDefault(domain)
    if cookieJar == nil:
      cookieJar = CookieJar()
      map.jars[domain] = cookieJar
    cookie.hostOnly = not state.nextBool(iq)
    cookie.path = state.nextField(iq)
    cookie.secure = state.nextBool(iq)
    cookie.expires = state.nextInt64(iq)
    cookie.name = state.nextField(iq)
    cookie.value = state.nextField(iq)
    if not state.error:
      cookieJar.add(cookie, parseMode = true)
    else:
      warnings.add("skipped invalid cookie line " & $line)
    inc state.i
    inc line

# Consumes `ps'.
proc parse*(map: CookieJarMap; ps: PosixStream; mtime: int64;
    warnings: var seq[string]) =
  let src = ps.readAllOrMmap()
  map.parse(src.toOpenArray(), warnings)
  deallocMem(src)
  map.mtime = mtime
  ps.sclose()

proc c_rename(oldname, newname: cstring): cint {.importc: "rename",
  header: "<stdio.h>".}

proc write*(map: CookieJarMap; file: string): bool =
  let ps = newPosixStream(file)
  if ps != nil:
    var stats: Stat
    if fstat(ps.fd, stats) != -1 and S_ISREG(stats.st_mode):
      if int64(stats.st_mtime) > map.mtime:
        var dummy: seq[string] = @[]
        map.parse(ps, int64(stats.st_mtime), dummy)
      else:
        ps.sclose()
    else:
      ps.sclose()
  elif map.jars.len == 0:
    return true
  let tmp = file & '~'
  block write:
    let ps = newPosixStream(tmp, O_WRONLY or O_CREAT, 0o600)
    var i = 0
    let time = getTime().toUnix()
    if ps != nil:
      var buf = """
# Netscape HTTP Cookie file
# Autogenerated by Chawan.  Manually added cookies are normally
# preserved, but comments will be lost.

"""
      for name, jar in map.jars:
        for cookie in jar.cookies:
          if cookie.expires <= time or not cookie.persist:
            continue # session cookie
          if buf.len >= 4096: # flush
            if not ps.writeDataLoop(buf):
              ps.sclose()
              return false
            buf.setLen(0)
          if cookie.httpOnly:
            buf &= "#HttpOnly_"
          if cookie.domain != name:
            buf &= name & "@"
          if not cookie.hostOnly:
            buf &= '.'
          buf &= cookie.domain & '\t'
          const BoolMap = [false: "FALSE", true: "TRUE"]
          buf &= BoolMap[not cookie.hostOnly] & '\t' # flipped intentionally
          buf &= cookie.path & '\t'
          buf &= BoolMap[cookie.secure] & '\t'
          buf &= $cookie.expires & '\t'
          buf &= cookie.name & '\t'
          buf &= cookie.value & '\n'
          inc i
      if not ps.writeDataLoop(buf):
        ps.sclose()
        return false
    if i == 0:
      discard unlink(cstring(tmp))
      discard unlink(cstring(file))
      ps.sclose()
      return true
    if fsync(ps.fd) != 0:
      ps.sclose()
      return false
    ps.sclose()
    return c_rename(cstring(tmp), file) == 0

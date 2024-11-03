import std/options
import std/os
import std/posix
import std/strutils
import std/tables
import std/termios

import chagashi/charset
import chagashi/decoder
import chagashi/encoder
import config/config
import io/dynstream
import types/blob
import types/cell
import types/color
import types/opt
import types/winattrs
import utils/strwidth
import utils/twtstr

#TODO switch away from termcap...
const Termlib* = (proc(): string =
  const libs = [
    "terminfo", "mytinfo", "termlib", "termcap", "tinfo", "ncurses", "curses"
  ]
  for lib in libs:
    let res = staticExec("pkg-config --libs --silence-errors " & lib)
    if res != "":
      return res
  # Apparently on some systems pkg-config will fail to locate ncurses.
  const dirs = [
    "/lib", "/usr/lib", "/usr/local/lib"
  ]
  for lib in libs:
    for dir in dirs:
      if fileExists(dir & "/lib" & lib & ".a"):
        return "-l" & lib
  return ""
)()

const TermcapFound* = Termlib != ""

when TermcapFound:
  {.passl: Termlib.}
  {.push importc, cdecl.}
  proc tgetent(bp, name: cstring): cint
  proc tgetnum(id: cstring): cint
  proc tgetstr(id: cstring; area: ptr cstring): cstring
  proc tgoto(cap: cstring; x, y: cint): cstring
  {.pop.}

type
  TermcapCap = enum
    ce # clear till end of line
    cd # clear display
    cm # cursor move
    ti # terminal init (=smcup)
    te # terminal end (=rmcup)
    so # start standout mode
    md # start bold mode
    us # start underline mode
    mr # start reverse mode
    mb # start blink mode
    ZH # start italic mode
    se # end standout mode
    ue # end underline mode
    ZR # end italic mode
    me # end all formatting modes
    vs # enhance cursor
    vi # make cursor invisible
    ve # reset cursor to normal

  TermcapCapNumeric = enum
    Co # color?

  Termcap = ref object
    bp: array[1024, uint8]
    funcstr: array[256, uint8]
    caps: array[TermcapCap, cstring]
    numCaps: array[TermcapCapNumeric, cint]

  CanvasImage* = ref object
    pid: int
    imageId: int
    # relative position on screen
    x: int
    y: int
    # original dimensions (after resizing)
    width: int
    height: int
    # offset (crop start)
    offx: int
    offy: int
    # size cap (crop end)
    # Note: this 0-based, so the final display size is
    # (dispw - offx, disph - offy)
    dispw: int
    disph: int
    damaged: bool
    marked*: bool
    dead: bool
    transparent: bool
    preludeLen: int
    kittyId: int
    # 0 if kitty
    erry: int
    # absolute x, y in container
    rx: int
    ry: int
    data: Blob

  Terminal* = ref object
    cs*: Charset
    te: TextEncoder
    config: Config
    istream*: PosixStream
    outfile: File
    cleared: bool
    canvas: seq[FixedCell]
    canvasImages*: seq[CanvasImage]
    imagesToClear*: seq[CanvasImage]
    lineDamage: seq[int]
    attrs*: WindowAttributes
    colorMode: ColorMode
    formatMode: set[FormatFlag]
    imageMode*: ImageMode
    smcup: bool
    tc: Termcap
    setTitle: bool
    stdinUnblocked: bool
    stdinWasUnblocked: bool
    origTermios: Termios
    defaultBackground: RGBColor
    defaultForeground: RGBColor
    ibuf*: string # buffer for chars when we can't process them
    sixelRegisterNum*: int
    sixelMaxWidth*: int
    sixelMaxHeight: int
    kittyId: int # counter for kitty image (*not* placement) ids.
    cursorx: int
    cursory: int
    colorMap: array[16, RGBColor]
    tname: string

# control sequence introducer
const CSI = "\e["

# primary device attributes
const DA1 = CSI & 'c'

# push/pop current title to/from the terminal's title stack
const XTPUSHTITLE = CSI & "22t"
const XTPOPTITLE = CSI & "23t"

# report xterm text area size in pixels
const GEOMPIXEL = CSI & "14t"

# report cell size
const CELLSIZE = CSI & "16t"

# report window size in chars
const GEOMCELL = CSI & "18t"

# allow shift-key to override mouse protocol
const XTSHIFTESCAPE = CSI & ">0s"

# query sixel register number
template XTSMGRAPHICS(pi, pa, pv: untyped): string =
  CSI & '?' & $pi & ';' & $pa & ';' & $pv & 'S'

# number of color registers
const XTNUMREGS = XTSMGRAPHICS(1, 1, 0)

# image dimensions
const XTIMGDIMS = XTSMGRAPHICS(2, 1, 0)

# horizontal & vertical position
template HVP(y, x: int): string =
  CSI & $y & ';' & $x & 'f'

# erase line
const EL = CSI & 'K'

# erase display
const ED = CSI & 'J'

# device control string
const DCS = "\eP"

# string terminator
const ST = "\e\\"

# xterm get terminal capability rgb
const XTGETTCAPRGB = DCS & "+q524742" & ST

# OS command
template OSC(s: varargs[string, `$`]): string =
  "\e]" & s.join(';') & '\a'

template XTSETTITLE(s: string): string =
  OSC(0, s)

const XTGETFG = OSC(10, "?") # get foreground color
const XTGETBG = OSC(11, "?") # get background color
const XTGETANSI = block: # get ansi colors
  var s = ""
  for n in 0 ..< 16:
    s &= OSC(4, n, "?")
  s

# DEC set
template DECSET(s: varargs[string, `$`]): string =
  "\e[?" & s.join(';') & 'h'

# DEC reset
template DECRST(s: varargs[string, `$`]): string =
  "\e[?" & s.join(';') & 'l'

# alt screen
const SMCUP = DECSET(1049)
const RMCUP = DECRST(1049)

# mouse tracking
const SGRMOUSEBTNON = DECSET(1002, 1006)
const SGRMOUSEBTNOFF = DECRST(1002, 1006)

# show/hide cursor
const CNORM = DECSET(25)
const CIVIS = DECRST(25)

# application program command
const APC = "\e_"

const KITTYQUERY = APC & "Gi=1,a=q;" & ST

when TermcapFound:
  func hascap(term: Terminal; c: TermcapCap): bool = term.tc.caps[c] != nil
  func cap(term: Terminal; c: TermcapCap): string = $term.tc.caps[c]
  func ccap(term: Terminal; c: TermcapCap): cstring = term.tc.caps[c]

proc write(term: Terminal; s: openArray[char]) =
  # write() calls $ on s, so we must writeBuffer
  if s.len > 0:
    discard term.outfile.writeBuffer(unsafeAddr s[0], s.len)

proc write(term: Terminal; s: string) =
  term.outfile.write(s)

proc write(term: Terminal; s: cstring) =
  term.outfile.write(s)

proc readChar*(term: Terminal): char =
  if term.ibuf.len == 0:
    result = term.istream.sreadChar()
  else:
    result = term.ibuf[0]
    term.ibuf.delete(0..0)

proc flush*(term: Terminal) =
  term.outfile.flushFile()

proc cursorGoto(term: Terminal; x, y: int): string =
  when TermcapFound:
    if term.tc != nil:
      return $tgoto(term.ccap cm, cint(x), cint(y))
  return HVP(y + 1, x + 1)

proc clearEnd(term: Terminal): string =
  when TermcapFound:
    if term.tc != nil:
      return term.cap ce
  return EL

proc clearDisplay(term: Terminal): string =
  when TermcapFound:
    if term.tc != nil:
      return term.cap cd
  return ED

proc isatty*(file: File): bool =
  return file.getFileHandle().isatty() != 0

proc isatty*(term: Terminal): bool =
  return term.istream != nil and term.istream.fd.isatty() != 0 and
    term.outfile.isatty()

proc anyKey*(term: Terminal; msg = "[Hit any key]") =
  if term.isatty():
    term.write(term.clearEnd() & msg)
    term.flush()
    discard term.istream.sreadChar()

proc resetFormat(term: Terminal): string =
  when TermcapFound:
    if term.tc != nil:
      return term.cap me
  return CSI & 'm'

const FormatCodes: array[FormatFlag, tuple[s, e: uint8]] = [
  ffBold: (1u8, 22u8),
  ffItalic: (3u8, 23u8),
  ffUnderline: (4u8, 24u8),
  ffReverse: (7u8, 27u8),
  ffStrike: (9u8, 29u8),
  ffOverline: (53u8, 55u8),
  ffBlink: (5u8, 25u8),
]

proc startFormat(term: Terminal; flag: FormatFlag): string =
  when TermcapFound:
    if term.tc != nil:
      case flag
      of ffBold: return term.cap md
      of ffUnderline: return term.cap us
      of ffReverse: return term.cap mr
      of ffBlink: return term.cap mb
      of ffItalic: return term.cap ZH
      else: discard
  return CSI & $FormatCodes[flag].s & 'm'

proc endFormat(term: Terminal; flag: FormatFlag): string =
  when TermcapFound:
    if term.tc != nil:
      case flag
      of ffUnderline: return term.cap ue
      of ffItalic: return term.cap ZR
      else: discard
  return CSI & $FormatCodes[flag].e & 'm'

proc setCursor*(term: Terminal; x, y: int) =
  assert x >= 0 and y >= 0
  if x != term.cursorx or y != term.cursory:
    term.write(term.cursorGoto(x, y))
    term.cursorx = x
    term.cursory = y

proc enableAltScreen(term: Terminal): string =
  when TermcapFound:
    if term.tc != nil and term.hascap ti:
      return term.cap ti
  return SMCUP

proc disableAltScreen(term: Terminal): string =
  when TermcapFound:
    if term.tc != nil and term.hascap te:
      return term.cap te
  return RMCUP

proc getRGB(term: Terminal; a: CellColor; termDefault: RGBColor): RGBColor =
  case a.t
  of ctNone:
    return termDefault
  of ctANSI:
    let n = a.ansi
    if uint8(n) >= 16:
      return n.toRGB()
    return term.colorMap[uint8(n)]
  of ctRGB:
    return a.rgb

# Use euclidian distance to quantize RGB colors.
proc approximateANSIColor(term: Terminal; rgb, termDefault: RGBColor):
    CellColor =
  var a = 0
  var n = -1
  if rgb == termDefault:
    return defaultColor
  for i in -1 .. term.colorMap.high:
    let color = if i >= 0:
      term.colorMap[i]
    else:
      termDefault
    if color == rgb:
      return ANSIColor(i).cellColor()
    {.push overflowChecks:off.}
    let x = int(color.r) - int(rgb.r)
    let y = int(color.g) - int(rgb.g)
    let z = int(color.b) - int(rgb.b)
    let xx = x * x
    let yy = y * y
    let zz = z * z
    let b = xx + yy + zz
    {.pop.}
    if i == -1 or b < a:
      n = i
      a = b
  return if n == -1: defaultColor else: ANSIColor(n).cellColor()

# Return a fgcolor contrasted to the background by the minimum configured
# contrast.
proc correctContrast(term: Terminal; bgcolor, fgcolor: CellColor): CellColor =
  let contrast = term.config.display.minimum_contrast
  let cfgcolor = fgcolor
  let bgcolor = term.getRGB(bgcolor, term.defaultBackground)
  let fgcolor = term.getRGB(fgcolor, term.defaultForeground)
  let bgY = int(bgcolor.Y)
  var fgY = int(fgcolor.Y)
  let diff = abs(bgY - fgY)
  if diff < contrast:
    if bgY > fgY:
      fgY = bgY - contrast
      if fgY < 0:
        fgY = bgY + contrast
        if fgY > 255:
          fgY = 0
    else:
      fgY = bgY + contrast
      if fgY > 255:
        fgY = bgY - contrast
        if fgY < 0:
          fgY = 255
    let newrgb = YUV(uint8(fgY), fgcolor.U, fgcolor.V)
    case term.colorMode
    of cmTrueColor:
      return cellColor(newrgb)
    of cmANSI:
      return term.approximateANSIColor(newrgb, term.defaultForeground)
    of cmEightBit:
      return cellColor(newrgb.toEightBit())
    of cmMonochrome:
      assert false
  return cfgcolor

proc addColorSGR(res: var string; c: CellColor; bgmod: uint8) =
  res &= CSI
  case c.t
  of ctNone:
    res &= 39 + bgmod
  of ctANSI:
    let n = uint8(c.ansi)
    if n < 16:
      if n < 8:
        res &= 30 + bgmod + n
      else:
        res &= 82 + bgmod + n
    else:
      res &= 38 + bgmod
      res &= ";5;"
      res &= n
  of ctRGB:
    let rgb = c.rgb
    res &= 38 + bgmod
    res &= ";2;"
    res &= rgb.r
    res &= ';'
    res &= rgb.g
    res &= ';'
    res &= rgb.b
  res &= 'm'

# If needed, quantize colors based on the color mode.
proc reduceColors(term: Terminal; cellf: var Format) =
  case term.colorMode
  of cmANSI:
    if cellf.bgcolor.t == ctANSI and uint8(cellf.bgcolor.ansi) > 15:
      cellf.bgcolor = cellf.fgcolor.ansi.toRGB().cellColor()
    if cellf.bgcolor.t == ctRGB:
      cellf.bgcolor = term.approximateANSIColor(cellf.bgcolor.rgb,
        term.defaultBackground)
    if cellf.fgcolor.t == ctANSI and uint8(cellf.fgcolor.ansi) > 15:
      cellf.fgcolor = cellf.fgcolor.ansi.toRGB().cellColor()
    if cellf.fgcolor.t == ctRGB:
      if cellf.bgcolor.t == ctNone:
        cellf.fgcolor = term.approximateANSIColor(cellf.fgcolor.rgb,
          term.defaultForeground)
      else:
        # ANSI fgcolor + bgcolor at the same time is broken
        cellf.fgcolor = defaultColor
  of cmEightBit:
    if cellf.bgcolor.t == ctRGB:
      cellf.bgcolor = cellf.bgcolor.rgb.toEightBit().cellColor()
    if cellf.fgcolor.t == ctRGB:
      cellf.fgcolor = cellf.fgcolor.rgb.toEightBit().cellColor()
  of cmMonochrome, cmTrueColor:
    discard # nothing to do

proc processFormat*(res: var string; term: Terminal; format: var Format;
    cellf: Format) =
  for flag in FormatFlag:
    if flag in term.formatMode:
      if flag in format.flags and flag notin cellf.flags:
        res &= term.endFormat(flag)
      if flag notin format.flags and flag in cellf.flags:
        res &= term.startFormat(flag)
  var cellf = cellf
  term.reduceColors(cellf)
  if term.colorMode != cmMonochrome:
    cellf.fgcolor = term.correctContrast(cellf.bgcolor, cellf.fgcolor)
    if cellf.fgcolor != format.fgcolor:
      res.addColorSGR(cellf.fgcolor, bgmod = 0)
    if cellf.bgcolor != format.bgcolor:
      res.addColorSGR(cellf.bgcolor, bgmod = 10)
  format = cellf

proc setTitle*(term: Terminal; title: string) =
  if term.setTitle:
    term.write(XTSETTITLE(title.replaceControls()))

proc enableMouse*(term: Terminal) =
  term.write(XTSHIFTESCAPE & SGRMOUSEBTNON)

proc disableMouse*(term: Terminal) =
  term.write(SGRMOUSEBTNOFF)

proc encodeAllQMark(res: var string; start: int; te: TextEncoder;
    iq: openArray[uint8]; w: var int) =
  var n = 0
  while true:
    case te.encode(iq, res.toOpenArrayByte(0, res.high), n)
    of terDone:
      res.setLen(n)
      case te.finish()
      of tefrOutputISO2022JPSetAscii:
        res &= "\e(B"
      of tefrDone:
        discard
      break
    of terReqOutput:
      res.setLen(res.len * 2)
    of terError:
      res.setLen(n)
      res &= '?'
      # fix up width if char was double width
      if w != -1:
        w += 1 - te.c.width()
        n = res.len

proc processOutputString*(res: var string; term: Terminal; s: openArray[char];
    w: var int) =
  if s.len == 0:
    return
  if s.validateUTF8Surr() != -1:
    res &= '?'
    if w != -1:
      inc w
    return
  if w != -1:
    for u in s.points:
      assert u > 0x7F or char(u) notin Controls
      w += u.width()
  let L = res.len
  res.setLen(L + s.len)
  if term.te == nil:
    # The output encoding matches the internal representation.
    copyMem(addr res[L], unsafeAddr s[0], s.len)
  else:
    # Output is not utf-8, so we must encode it first.
    res.encodeAllQMark(L, term.te, s.toOpenArrayByte(0, s.high), w)

proc generateFullOutput(term: Terminal): string =
  var format = Format()
  result = term.cursorGoto(0, 0)
  result &= term.resetFormat()
  result &= term.clearDisplay()
  for y in 0 ..< term.attrs.height:
    if y != 0:
      result &= "\r\n"
    var w = 0
    for x in 0 ..< term.attrs.width:
      while w < x:
        result &= " "
        inc w
      let cell = addr term.canvas[y * term.attrs.width + x]
      result.processFormat(term, format, cell.format)
      result.processOutputString(term, cell.str, w)
    term.lineDamage[y] = term.attrs.width

proc generateSwapOutput(term: Terminal): string =
  result = ""
  var vy = -1
  for y in 0 ..< term.attrs.height:
    # set cx to x of the first change
    let cx = term.lineDamage[y]
    # w will track the current position on screen
    var w = cx
    if cx < term.attrs.width:
      if cx == 0 and vy != -1:
        while vy < y:
          result &= "\r\n"
          inc vy
      else:
        result &= term.cursorGoto(cx, y)
        vy = y
      result &= term.resetFormat()
      var format = Format()
      for x in cx ..< term.attrs.width:
        while w < x: # if previous cell had no width, catch up with x
          result &= ' '
          inc w
        let cell = term.canvas[y * term.attrs.width + x]
        result.processFormat(term, format, cell.format)
        result.processOutputString(term, cell.str, w)
      if w < term.attrs.width:
        result &= term.clearEnd()
      # damage is gone
      term.lineDamage[y] = term.attrs.width

proc hideCursor*(term: Terminal) =
  when TermcapFound:
    if term.tc != nil:
      term.write(term.ccap vi)
      return
  term.write(CIVIS)

proc showCursor*(term: Terminal) =
  when TermcapFound:
    if term.tc != nil:
      term.write(term.ccap ve)
      return
  term.write(CNORM)

proc writeGrid*(term: Terminal; grid: FixedGrid; x = 0, y = 0) =
  for ly in y ..< y + grid.height:
    var lastx = 0
    for lx in x ..< x + grid.width:
      let i = ly * term.attrs.width + lx
      let cell = grid[(ly - y) * grid.width + (lx - x)]
      if term.canvas[i].str != "":
        # if there is a change, we have to start from the last x with
        # a string (otherwise we might overwrite half of a double-width char)
        lastx = lx
      if cell != term.canvas[i]:
        term.canvas[i] = cell
        term.lineDamage[ly] = min(term.lineDamage[ly], lastx)

proc applyConfigDimensions(term: Terminal) =
  # screen dimensions
  if term.attrs.width == 0 or term.config.display.force_columns:
    term.attrs.width = int(term.config.display.columns)
  if term.attrs.height == 0 or term.config.display.force_lines:
    term.attrs.height = int(term.config.display.lines)
  if term.attrs.ppc == 0 or term.config.display.force_pixels_per_column:
    term.attrs.ppc = int(term.config.display.pixels_per_column)
  if term.attrs.ppl == 0 or term.config.display.force_pixels_per_line:
    term.attrs.ppl = int(term.config.display.pixels_per_line)
  term.attrs.widthPx = term.attrs.ppc * term.attrs.width
  term.attrs.heightPx = term.attrs.ppl * term.attrs.height
  if term.imageMode == imSixel:
    if term.sixelMaxWidth == 0:
      term.sixelMaxWidth = term.attrs.widthPx
    if term.sixelMaxHeight == 0:
      term.sixelMaxHeight = term.attrs.heightPx
    # xterm acts weird even if I don't fill in the missing rows, so
    # just round down instead.
    term.sixelMaxHeight = (term.sixelMaxHeight div 6) * 6

proc applyConfig(term: Terminal) =
  # colors, formatting
  if term.config.display.color_mode.isSome:
    term.colorMode = term.config.display.color_mode.get
  if term.config.display.format_mode.isSome:
    term.formatMode = term.config.display.format_mode.get
  for fm in FormatFlag:
    if fm in term.config.display.no_format_mode:
      term.formatMode.excl(fm)
  if term.config.display.image_mode.isSome:
    term.imageMode = term.config.display.image_mode.get
  if term.imageMode == imSixel and term.config.display.sixel_colors.isSome:
    let n = term.config.display.sixel_colors.get
    term.sixelRegisterNum = clamp(n, 2, 65535)
  if term.isatty():
    if term.config.display.alt_screen.isSome:
      term.smcup = term.config.display.alt_screen.get
    term.setTitle = term.config.display.set_title
  if term.config.display.default_background_color.isSome:
    term.defaultBackground = term.config.display.default_background_color.get
  if term.config.display.default_foreground_color.isSome:
    term.defaultForeground = term.config.display.default_foreground_color.get
  # charsets
  if term.config.encoding.display_charset.isSome:
    term.cs = term.config.encoding.display_charset.get
  else:
    term.cs = DefaultCharset
    for s in ["LC_ALL", "LC_CTYPE", "LANG"]:
      let env = getEnv(s)
      if env == "":
        continue
      let cs = getLocaleCharset(env)
      if cs != CHARSET_UNKNOWN:
        term.cs = cs
        break
    if term.cs in {CHARSET_UTF_8, CHARSET_UTF_16_LE, CHARSET_UTF_16_BE,
        CHARSET_REPLACEMENT}:
      term.cs = CHARSET_UTF_8
    else:
      term.te = newTextEncoder(term.cs)
  term.applyConfigDimensions()

proc outputGrid*(term: Terminal) =
  term.write(term.resetFormat())
  if term.config.display.force_clear or not term.cleared:
    term.write(term.generateFullOutput())
    term.cleared = true
  else:
    term.write(term.generateSwapOutput())
  term.cursorx = -1
  term.cursory = -1

func findImage(term: Terminal; pid, imageId: int; rx, ry, width, height,
    erry, offx, dispw: int): CanvasImage =
  for it in term.canvasImages:
    if not it.dead and it.pid == pid and it.imageId == imageId and
        it.width == width and it.height == height and
        it.rx == rx and it.ry == ry and
        (term.imageMode != imSixel or it.erry == erry and it.dispw == dispw and
          it.offx == offx):
      return it
  return nil

# x, y, maxw, maxh in cells
# x, y can be negative, then image starts outside the screen
proc positionImage(term: Terminal; image: CanvasImage; x, y, maxw, maxh: int):
    bool =
  image.x = x
  image.y = y
  let xpx = x * term.attrs.ppc
  let ypx = y * term.attrs.ppl
  # calculate offset inside image to start from
  image.offx = -min(xpx, 0)
  image.offy = -min(ypx, 0)
  # calculate maximum image size that fits on the screen relative to the image
  # origin (*not* offx/offy)
  let maxwpx = maxw * term.attrs.ppc
  let maxhpx = maxh * term.attrs.ppl
  var width = image.width
  var height = image.height
  if term.imageMode == imSixel:
    # we *could* scale the images down, but this doesn't really look
    # like a problem worth solving. just set the max sizes in xterm
    # appropriately.
    width = min(width - image.offx, term.sixelMaxWidth) + image.offx
    height = min(height - image.offy, term.sixelMaxHeight) + image.offy
  image.dispw = min(width + xpx, maxwpx) - xpx
  image.disph = min(height + ypx, maxhpx) - ypx
  image.damaged = true
  return image.dispw > image.offx and image.disph > image.offy

proc clearImage(term: Terminal; image: CanvasImage; maxh: int) =
  case term.imageMode
  of imNone: discard
  of imSixel:
    # we must clear sixels the same way as we clear text.
    let h = (image.height + term.attrs.ppl - 1) div term.attrs.ppl # ceil
    let ey = min(image.y + h, maxh)
    let x = max(image.x, 0)
    for y in max(image.y, 0) ..< ey:
      term.lineDamage[y] = min(term.lineDamage[y], x)
  of imKitty:
    term.imagesToClear.add(image)

proc clearImages*(term: Terminal; maxh: int) =
  for image in term.canvasImages:
    if not image.marked:
      term.clearImage(image, maxh)
    image.marked = false

proc checkImageDamage*(term: Terminal; maxw, maxh: int) =
  if term.imageMode == imSixel:
    for image in term.canvasImages:
      # check if any line of our image is damaged
      let h = (image.height + term.attrs.ppl - 1) div term.attrs.ppl # ceil
      let ey0 = min(image.y + h, maxh)
      # here we floor, so that a last line with rounding error (which
      # will not fully cover text) is always cleared
      let ey1 = min(image.y + image.height div term.attrs.ppl, maxh)
      let x = max(image.x, 0)
      let mx = min(image.x + image.dispw div term.attrs.ppc, maxw)
      for y in max(image.y, 0) ..< ey0:
        let od = term.lineDamage[y]
        if image.transparent and od > x:
          image.damaged = true
          if od < mx:
            # damage starts inside this image; move it to its beginning.
            term.lineDamage[y] = x
        elif not image.transparent and od < mx:
          image.damaged = true
          if y >= ey1:
            break
          if od >= image.x:
            # damage starts inside this image; skip clear (but only if
            # the damage was not caused by a printing character)
            var textFound = false
            let si = y * term.attrs.width
            for i in si + od ..< si + term.attrs.width:
              if term.canvas[i].str.len > 0 and term.canvas[i].str[0] != ' ':
                textFound = true
                break
            if not textFound:
              term.lineDamage[y] = mx

proc loadImage*(term: Terminal; data: Blob; pid, imageId, x, y, width, height,
    rx, ry, maxw, maxh, erry, offx, dispw, preludeLen: int; transparent: bool;
    redrawNext: var bool): CanvasImage =
  if (let image = term.findImage(pid, imageId, rx, ry, width, height, erry,
        offx, dispw); image != nil):
    # reuse image on screen
    if image.x != x or image.y != y or redrawNext:
      # only clear sixels; with kitty we just move the existing image
      if term.imageMode == imSixel:
        term.clearImage(image, maxh)
      if not term.positionImage(image, x, y, maxw, maxh):
        # no longer on screen
        image.dead = true
        return nil
    # only mark old images; new images will not be checked until the next
    # initImages call.
    image.marked = true
    return image
  # new image
  let image = CanvasImage(
    pid: pid,
    imageId: imageId,
    data: data,
    rx: rx,
    ry: ry,
    width: width,
    height: height,
    erry: erry,
    transparent: transparent,
    preludeLen: preludeLen
  )
  if term.positionImage(image, x, y, maxw, maxh):
    redrawNext = true
    return image
  # no longer on screen
  return nil

func getU32BE(data: openArray[char]; i: int): uint32 =
  return uint32(data[i + 3]) or
    (uint32(data[i + 2]) shl 8) or
    (uint32(data[i + 1]) shl 16) or
    (uint32(data[i]) shl 24)

proc appendSixelAttrs(outs: var string; data: openArray[char];
    realw, realh: int) =
  var i = 0
  while i < data.len:
    let c = data[i]
    outs &= c
    inc i
    if c == '"': # set raster attrs
      break
  while i < data.len and data[i] != '#': # skip aspect ratio attrs
    inc i
  outs &= "1;1;" & $realw & ';' & $realh
  if i < data.len:
    let ol = outs.len
    outs.setLen(ol + data.len - i)
    copyMem(addr outs[ol], unsafeAddr data[i], data.len - i)

proc outputSixelImage(term: Terminal; x, y: int; image: CanvasImage;
    data: openArray[char]) =
  let offx = image.offx
  let offy = image.offy
  let dispw = image.dispw
  let disph = image.disph
  let realw = dispw - offx
  let realh = disph - offy
  let preludeLen = image.preludeLen
  if preludeLen > data.len or data.len < 4:
    return
  let L = data.len - int(data.getU32BE(data.len - 4)) - 4
  if L < 0:
    return
  var outs = term.cursorGoto(x, y)
  outs.appendSixelAttrs(data.toOpenArray(0, preludeLen - 1), realw, realh)
  term.write(outs)
  # Note: we only crop images when it is possible to do so in near constant
  # time. Otherwise, the image is re-coded in a cropped form.
  if realh == image.height: # don't crop
    term.write(data.toOpenArray(preludeLen, L - 1))
  else:
    let si = preludeLen + int(data.getU32BE(L + (offy div 6) * 4))
    if si >= data.len: # bounds check
      term.write(ST)
    elif disph == image.height: # crop top only
      term.write(data.toOpenArray(si, L - 1))
    else: # crop both top & bottom
      let ed6 = (disph - image.erry) div 6
      let ei = preludeLen + int(data.getU32BE(L + ed6 * 4)) - 1
      if ei <= data.len: # bounds check
        term.write(data.toOpenArray(si, ei - 1))
      # calculate difference between target Y & actual position in the map
      # note: it must be offset by image.erry; that's where the map starts.
      let herry = disph - (ed6 * 6 + image.erry)
      if herry > 0:
        # can't write out the last row completely; mask off the bottom part.
        let mask = (1u8 shl herry) - 1
        var s = "-"
        var i = ei + 1
        while i < L and (let c = data[i]; c notin {'-', '\e'}): # newline or ST
          let u = uint8(c) - 0x3F # may underflow, but that's no problem
          if u < 0x40:
            s &= char((u and mask) + 0x3F)
          else:
            s &= c
          inc i
        term.write(s)
      term.write(ST)

proc outputSixelImage(term: Terminal; x, y: int; image: CanvasImage) =
  var p = cast[ptr UncheckedArray[char]](image.data.buffer)
  if image.data.size > 0:
    let H = image.data.size - 1
    term.outputSixelImage(x, y, image, p.toOpenArray(0, H))

proc outputKittyImage(term: Terminal; x, y: int; image: CanvasImage) =
  var outs = term.cursorGoto(x, y) &
    APC & "GC=1,s=" & $image.width & ",v=" & $image.height &
    ",x=" & $image.offx & ",y=" & $image.offy &
    ",w=" & $(image.dispw - image.offx) &
    ",h=" & $(image.disph - image.offy) &
    # for now, we always use placement id 1
    ",p=1,q=2"
  if image.kittyId != 0:
    outs &= ",i=" & $image.kittyId & ",a=p;" & ST
    term.write(outs)
    term.flush()
    return
  inc term.kittyId # skip i=0
  image.kittyId = term.kittyId
  outs &= ",i=" & $image.kittyId
  const MaxBytes = 4096 * 3 div 4
  var i = MaxBytes
  # transcode to RGB
  let p = cast[ptr UncheckedArray[uint8]](image.data.buffer)
  let L = image.data.size
  let m = if i < L: '1' else: '0'
  outs &= ",a=T,f=100,m=" & m & ';'
  outs.btoa(p.toOpenArray(0, min(L, i) - 1))
  outs &= ST
  term.write(outs)
  while i < L:
    let j = i
    i += MaxBytes
    let m = if i < L: '1' else: '0'
    var outs = APC & "Gm=" & m & ';'
    outs.btoa(p.toOpenArray(j, min(L, i) - 1))
    outs &= ST
    term.write(outs)

proc outputImages*(term: Terminal) =
  if term.imageMode == imKitty:
    # clean up unused kitty images
    var s = ""
    for image in term.imagesToClear:
      if image.kittyId == 0:
        continue # maybe it was never displayed...
      s &= APC & "Ga=d,d=I,i=" & $image.kittyId & ",p=1,q=2;" & ST
    term.write(s)
    term.imagesToClear.setLen(0)
  for image in term.canvasImages:
    if image.damaged:
      assert image.dispw > 0 and image.disph > 0
      let x = max(image.x, 0)
      let y = max(image.y, 0)
      case term.imageMode
      of imNone: assert false
      of imSixel: term.outputSixelImage(x, y, image)
      of imKitty: term.outputKittyImage(x, y, image)
      image.damaged = false

proc clearCanvas*(term: Terminal) =
  term.cleared = false
  let maxw = term.attrs.width
  let maxh = term.attrs.height - 1
  var newImages: seq[CanvasImage] = @[]
  for image in term.canvasImages:
    if term.positionImage(image, image.x, image.y, maxw, maxh):
      image.damaged = true
      image.marked = true
      newImages.add(image)
  term.clearImages(maxh)
  term.canvasImages = newImages

# see https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
proc disableRawMode(term: Terminal) =
  discard tcSetAttr(term.istream.fd, TCSAFLUSH, addr term.origTermios)

proc enableRawMode(term: Terminal) =
  discard tcGetAttr(term.istream.fd, addr term.origTermios)
  var raw = term.origTermios
  raw.c_iflag = raw.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  raw.c_oflag = raw.c_oflag and not (OPOST)
  raw.c_cflag = raw.c_cflag or CS8
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or ISIG or IEXTEN)
  discard tcSetAttr(term.istream.fd, TCSAFLUSH, addr raw)

proc unblockStdin*(term: Terminal) =
  if term.isatty():
    term.istream.setBlocking(false)
    term.stdinUnblocked = true

proc restoreStdin*(term: Terminal) =
  if term.stdinUnblocked:
    term.istream.setBlocking(true)
    term.stdinUnblocked = false

proc quit*(term: Terminal) =
  if term.isatty():
    term.disableRawMode()
    if term.config.input.use_mouse:
      term.disableMouse()
    if term.smcup:
      if term.imageMode == imSixel:
        # xterm seems to keep sixels in the alt screen; clear these so
        # it doesn't flash in the user's face the next time they do smcup
        term.write(term.clearDisplay())
      term.write(term.disableAltScreen())
    else:
      term.write(term.cursorGoto(0, term.attrs.height - 1) &
        term.resetFormat() & "\n")
    if term.setTitle:
      term.write(XTPOPTITLE)
    term.showCursor()
    term.clearCanvas()
    if term.stdinUnblocked:
      term.restoreStdin()
      term.stdinWasUnblocked = true
  term.flush()

when TermcapFound:
  proc loadTermcap(term: Terminal) =
    let tc = Termcap()
    var res = tgetent(cast[cstring](addr tc.bp), cstring(term.tname))
    if res == 0: # retry as dosansi
      res = tgetent(cast[cstring](addr tc.bp), "dosansi")
    if res > 0: # success
      term.tc = tc
      for id in TermcapCap:
        tc.caps[id] = tgetstr(cstring($id), cast[ptr cstring](addr tc.funcstr))
      for id in TermcapCapNumeric:
        tc.numCaps[id] = tgetnum(cstring($id))

type
  QueryAttrs = enum
    qaAnsiColor, qaRGB, qaSixel, qaKittyImage, qaSyncTermFix

  QueryResult = object
    success: bool
    attrs: set[QueryAttrs]
    fgcolor: Option[RGBColor]
    bgcolor: Option[RGBColor]
    colorMap: seq[tuple[n: int; rgb: RGBColor]]
    widthPx: int
    heightPx: int
    ppc: int
    ppl: int
    width: int
    height: int
    sixelMaxWidth: int
    sixelMaxHeight: int
    registers: int

proc consumeIntUntil(term: Terminal; sentinel: char): int =
  var n = 0
  while (let c = term.readChar(); c != sentinel):
    if (let x = decValue(c); x != -1):
      n *= 10
      n += x
    else:
      return -1
  return n

proc consumeIntGreedy(term: Terminal; lastc: var char): int =
  var n = 0
  while true:
    let c = term.readChar()
    if (let x = decValue(c); x != -1):
      n *= 10
      n += x
    else:
      lastc = c
      break
  return n

proc eatColor(term: Terminal; tc: set[char]; wasEsc: var bool): uint8 =
  var val = 0u8
  var i = 0
  var c = char(0)
  while (c = term.readChar(); c notin tc):
    let v0 = hexValue(c)
    if i > 4 or v0 == -1:
      break # wat
    let v = uint8(v0)
    if i == 0: # 1st place - expand it for when we don't get a 2nd place
      val = (v shl 4) or v
    elif i == 1: # 2nd place - clear expanded placeholder from 1st place
      val = (val and not 0xFu8) or v
    # all other places are irrelevant
    inc i
  wasEsc = c == '\e'
  return val

proc skipUntil(term: Terminal; c: char) =
  while term.readChar() != c:
    discard

proc queryAttrs(term: Terminal; windowOnly: bool): QueryResult =
  const tcapRGB = 0x524742 # RGB supported?
  if not windowOnly:
    var outs = ""
    if term.tname != "screen":
      # screen has a horrible bug (feature?) where the responses to
      # bg/fg queries are printed out of order (presumably because it
      # must ask the terminal first).
      #
      # Of course, I can't work around this either, because screen won't
      # respond from terminals that don't support this query. So I'll
      # do the sole reasonable thing and skip default color queries.
      #
      # (By the way, tmux works as expected. Sigh.)
      if term.config.display.default_background_color.isNone:
        outs &= XTGETBG
      if term.config.display.default_foreground_color.isNone:
        outs &= XTGETFG
    if term.config.display.image_mode.isNone:
      outs &= KITTYQUERY
      outs &= XTNUMREGS
      outs &= XTIMGDIMS
    elif term.config.display.image_mode.get == imSixel:
      outs &= XTNUMREGS
      outs &= XTIMGDIMS
    if term.config.display.color_mode.isNone:
      outs &= XTGETTCAPRGB
    outs &=
      XTGETANSI &
      GEOMPIXEL &
      CELLSIZE &
      GEOMCELL &
      DA1
    term.write(outs)
  else:
    const outs =
      GEOMPIXEL &
      CELLSIZE &
      GEOMCELL &
      XTIMGDIMS &
      DA1
    term.write(outs)
  term.flush()
  result = QueryResult(success: false, attrs: {})
  while true:
    template consume(term: Terminal): char =
      term.readChar()
    template fail =
      return
    template expect(term: Terminal; c: char) =
      if term.consume != c:
        fail
    template expect(term: Terminal; s: string) =
      for c in s:
        term.expect c
    term.expect '\e'
    case term.consume
    of '[':
      # CSI
      case (let c = term.consume; c)
      of '?': # DA1, XTSMGRAPHICS
        var params = newSeq[int]()
        var lastc = char(0)
        while lastc notin {'c', 'S'}:
          let n = term.consumeIntGreedy(lastc)
          if lastc notin {'c', 'S', ';'}:
            # skip entry
            break
          params.add(n)
        if lastc == 'c': # DA1
          for n in params:
            case n
            of 4: result.attrs.incl(qaSixel)
            of 22: result.attrs.incl(qaAnsiColor)
            else: discard
          result.success = true
          break
        else: # 'S' (XTSMGRAPHICS)
          if params.len >= 4:
            if params[0] == 2 and params[1] == 0:
              result.sixelMaxWidth = params[2]
              result.sixelMaxHeight = params[3]
          if params.len >= 3:
            if params[0] == 1 and params[1] == 0:
              result.registers = params[2]
      of '=':
        # = is SyncTERM's response to DA1. Nothing useful will come after this.
        term.skipUntil('c')
        # SyncTERM supports these.
        result.attrs.incl(qaSixel)
        result.attrs.incl(qaAnsiColor)
        # This will make us ask SyncTERM to stop moving the cursor on EOL.
        result.attrs.incl(qaSyncTermFix)
        result.success = true
        break # we're done
      of '4', '6', '8': # GEOMPIXEL, CELLSIZE, GEOMCELL
        term.expect ';'
        let height = term.consumeIntUntil(';')
        let width = term.consumeIntUntil('t')
        if width == -1 or height == -1:
          discard
        elif c == '4': # GEOMSIZE
          result.widthPx = width
          result.heightPx = height
        elif c == '6': # CELLSIZE
          result.ppc = width
          result.ppl = height
        elif c == '8': # GEOMCELL
          result.width = width
          result.height = height
      else: fail
    of ']':
      # OSC
      let c = term.consumeIntUntil(';')
      var n: int
      if c == 4:
        n = term.consumeIntUntil(';')
      if term.consume == 'r' and term.consume == 'g' and term.consume == 'b':
        term.expect ':'
        var wasEsc = false
        let r = term.eatColor({'/'}, wasEsc)
        let g = term.eatColor({'/'}, wasEsc)
        let b = term.eatColor({'\a', '\e'}, wasEsc)
        if wasEsc:
          # we got ST, not BEL; at least kitty does this
          term.expect '\\'
        let C = rgb(r, g, b)
        if c == 4:
          result.colorMap.add((n, C))
        elif c == 10:
          result.fgcolor = some(C)
        else: # 11
          result.bgcolor = some(C)
      else:
        # not RGB, give up
        term.skipUntil('\a')
    of 'P':
      # DCS
      let c = term.consume
      if c notin {'0', '1'}:
        fail
      term.expect "+r"
      if c == '1':
        var id = 0
        while (let c = term.consume; c != '='):
          if c notin AsciiHexDigit:
            fail
          id *= 0x10
          id += hexValue(c)
        term.skipUntil('\e') # ST (1)
        if id == tcapRGB:
          result.attrs.incl(qaRGB)
      else: # 0
        # pure insanity: kitty returns P0, but also +r524742 after. please
        # make up your mind!
        term.skipUntil('\e') # ST (1)
      term.expect '\\' # ST (2)
    of '_': # APC
      term.expect 'G'
      result.attrs.incl(qaKittyImage)
      term.skipUntil('\e') # ST (1)
      term.expect '\\' # ST (2)
    else:
      fail

type TermStartResult* = enum
  tsrSuccess, tsrDA1Fail

# when windowOnly, only refresh window size.
proc detectTermAttributes(term: Terminal; windowOnly: bool): TermStartResult =
  var res = tsrSuccess
  if not term.isatty():
    return res
  if not windowOnly:
    # set tname here because queryAttrs depends on it
    term.tname = getEnv("TERM")
    if term.tname == "":
      term.tname = "dosansi"
  var win: IOctl_WinSize
  if ioctl(term.istream.fd, TIOCGWINSZ, addr win) != -1:
    term.attrs.width = int(win.ws_col)
    term.attrs.height = int(win.ws_row)
    term.attrs.ppc = int(win.ws_xpixel) div term.attrs.width
    term.attrs.ppl = int(win.ws_ypixel) div term.attrs.height
  if term.config.display.query_da1:
    let r = term.queryAttrs(windowOnly)
    if r.success: # DA1 success
      if r.width != 0:
        term.attrs.width = r.width
        if r.ppc != 0:
          term.attrs.ppc = r.ppc
        elif r.widthPx != 0:
          term.attrs.ppc = r.widthPx div r.width
      if r.height != 0:
        term.attrs.height = r.height
        if r.ppl != 0:
          term.attrs.ppl = r.ppl
        elif r.heightPx != 0:
          term.attrs.ppl = r.heightPx div r.height
      if not windowOnly: # we don't check for kitty, so don't override this
        if qaKittyImage in r.attrs:
          term.imageMode = imKitty
        elif qaSixel in r.attrs or term.tname.startsWith("yaft"): # meh
          term.imageMode = imSixel
      if term.imageMode == imSixel: # adjust after windowChange
        if r.registers != 0:
          # I need at least 2 registers, and can't do anything with more
          # than 101 ^ 3.
          # In practice, terminals I've seen have between 256 - 65535; for now,
          # I'll stick with 65535 as the upper limit, because I have no way
          # to test if encoding time explodes with more or something.
          term.sixelRegisterNum = clamp(r.registers, 2, 65535)
        if term.sixelRegisterNum == 0:
          # assume 256 - tell me if you have more.
          term.sixelRegisterNum = 256
        term.sixelMaxWidth = r.sixelMaxWidth
        term.sixelMaxHeight = r.sixelMaxHeight
      if windowOnly:
        return
      if qaAnsiColor in r.attrs:
        term.colorMode = cmANSI
      if qaRGB in r.attrs:
        term.colorMode = cmTrueColor
      if qaSyncTermFix in r.attrs:
        term.write(static(CSI & "=5h"))
      # just assume the terminal doesn't choke on these.
      term.formatMode = {ffStrike, ffOverline}
      if r.bgcolor.isSome:
        term.defaultBackground = r.bgcolor.get
      if r.fgcolor.isSome:
        term.defaultForeground = r.fgcolor.get
      for (n, rgb) in r.colorMap:
        term.colorMap[n] = rgb
    else:
      term.sixelRegisterNum = 256
      # something went horribly wrong. set result to DA1 fail, pager will
      # alert the user
      res = tsrDA1Fail
  if windowOnly:
    return res
  if term.colorMode != cmTrueColor:
    let colorterm = getEnv("COLORTERM")
    if colorterm in ["24bit", "truecolor"]:
      term.colorMode = cmTrueColor
  when TermcapFound:
    term.loadTermcap()
    if term.tc != nil:
      term.smcup = term.hascap ti
      if term.colorMode < cmEightBit and term.tc.numCaps[Co] == 256:
        # due to termcap limitations, 256 is the highest possible number here
        term.colorMode = cmEightBit
      elif term.colorMode < cmANSI and term.tc.numCaps[Co] >= 8:
        term.colorMode = cmANSI
      if term.hascap ZH:
        term.formatMode.incl(ffItalic)
      if term.hascap us:
        term.formatMode.incl(ffUnderline)
      if term.hascap md:
        term.formatMode.incl(ffBold)
      if term.hascap mr:
        term.formatMode.incl(ffReverse)
      if term.hascap mb:
        term.formatMode.incl(ffBlink)
      return res
  term.smcup = true
  term.formatMode = {FormatFlag.low..FormatFlag.high}
  return res

type
  MouseInputType* = enum
    mitPress = "press", mitRelease = "release", mitMove = "move"

  MouseInputMod* = enum
    mimShift = "shift", mimCtrl = "ctrl", mimMeta = "meta"

  MouseInputButton* = enum
    mibLeft = (1, "left")
    mibMiddle = (2, "middle")
    mibRight = (3, "right")
    mibWheelUp = (4, "wheelUp")
    mibWheelDown = (5, "wheelDown")
    mibWheelLeft = (6, "wheelLeft")
    mibWheelRight = (7, "wheelRight")
    mibThumbInner = (8, "thumbInner")
    mibThumbTip = (9, "thumbTip")
    mibButton10 = (10, "button10")
    mibButton11 = (11, "button11")

  MouseInput* = object
    t*: MouseInputType
    button*: MouseInputButton
    mods*: set[MouseInputMod]
    col*: int
    row*: int

proc parseMouseInput*(term: Terminal): Opt[MouseInput] =
  template fail =
    return err()
  var btn = 0
  while (let c = term.readChar(); c != ';'):
    let n = decValue(c)
    if n == -1:
      fail
    btn *= 10
    btn += n
  var mods: set[MouseInputMod] = {}
  if (btn and 4) != 0:
    mods.incl(mimShift)
  if (btn and 8) != 0:
    mods.incl(mimCtrl)
  if (btn and 16) != 0:
    mods.incl(mimMeta)
  var px = 0
  while (let c = term.readChar(); c != ';'):
    let n = decValue(c)
    if n == -1:
      fail
    px *= 10
    px += n
  var py = 0
  var c: char
  while (c = term.readChar(); c notin {'m', 'M'}):
    let n = decValue(c)
    if n == -1:
      fail
    py *= 10
    py += n
  var t = if c == 'M': mitPress else: mitRelease
  if (btn and 32) != 0:
    t = mitMove
  var button = (btn and 3) + 1
  if (btn and 64) != 0:
    button += 3
  if (btn and 128) != 0:
    button += 7
  if button notin int(MouseInputButton.low)..int(MouseInputButton.high):
    return err()
  ok(MouseInput(
    t: t,
    mods: mods,
    button: MouseInputButton(button),
    col: px - 1,
    row: py - 1
  ))

proc windowChange*(term: Terminal) =
  discard term.detectTermAttributes(windowOnly = true)
  term.applyConfigDimensions()
  term.canvas = newSeq[FixedCell](term.attrs.width * term.attrs.height)
  term.lineDamage = newSeq[int](term.attrs.height)
  term.clearCanvas()

proc initScreen(term: Terminal) =
  # note: deinit happens in quit()
  if term.setTitle:
    term.write(XTPUSHTITLE)
  if term.smcup:
    term.write(term.enableAltScreen())
  if term.config.input.use_mouse:
    term.enableMouse()
  term.cursorx = -1
  term.cursory = -1

proc start*(term: Terminal; istream: PosixStream): TermStartResult =
  term.istream = istream
  if term.isatty():
    term.enableRawMode()
  result = term.detectTermAttributes(windowOnly = false)
  if result == tsrDA1Fail:
    term.config.display.query_da1 = false
  term.applyConfig()
  if term.isatty():
    term.initScreen()
  term.canvas = newSeq[FixedCell](term.attrs.width * term.attrs.height)
  term.lineDamage = newSeq[int](term.attrs.height)

proc restart*(term: Terminal) =
  if term.isatty():
    term.enableRawMode()
    if term.stdinWasUnblocked:
      term.unblockStdin()
      term.stdinWasUnblocked = false
    term.initScreen()

const ANSIColorMap = [
  rgb(0, 0, 0),
  rgb(205, 0, 0),
  rgb(0, 205, 0),
  rgb(205, 205, 0),
  rgb(0, 0, 238),
  rgb(205, 0, 205),
  rgb(0, 205, 205),
  rgb(229, 229, 229),
  rgb(127, 127, 127),
  rgb(255, 0, 0),
  rgb(0, 255, 0),
  rgb(255, 255, 0),
  rgb(92, 92, 255),
  rgb(255, 0, 255),
  rgb(0, 255, 255),
  rgb(255, 255, 255)
]

proc newTerminal*(outfile: File; config: Config): Terminal =
  const DefaultBackground = namedRGBColor("black").get
  const DefaultForeground = namedRGBColor("white").get
  return Terminal(
    outfile: outfile,
    config: config,
    defaultBackground: DefaultBackground,
    defaultForeground: DefaultForeground,
    colorMap: ANSIColorMap
  )

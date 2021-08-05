import terminal
import options
import uri
import strutils
import unicode

import ../types/enums

import ../utils/twtstr

import ../html/dom

import ../config

import ./buffer
import ./twtio
import ./term

proc clearStatusMsg*(at: int) =
  setCursorPos(0, at)
  eraseLine()

proc statusMsg*(str: string, at: int) =
  clearStatusMsg(at)
  print(str.ansiStyle(styleReverse).ansiReset())

type
  RenderState = object
    x: int
    y: int
    lastwidth: int
    fmtline: string
    rawline: string
    centerqueue: seq[Node]
    centerlen: int
    blanklines: int
    blankspaces: int
    nextspaces: int
    docenter: bool
    indent: int
    listval: int
    lastelem: Element

func newRenderState(): RenderState =
  return RenderState(blanklines: 1)

proc write(state: var RenderState, s: string) =
  state.fmtline &= s
  state.rawline &= s

proc write(state: var RenderState, fs: string, rs: string) =
  state.fmtline &= fs
  state.rawline &= rs

proc flushLine(buffer: Buffer, state: var RenderState) =
  if state.rawline.len == 0:
    inc state.blanklines
  assert(state.rawline.runeLen() < buffer.width, "line too long: (for node " &
         $state.lastelem & " " & $state.lastelem.style.display & ")\n" & state.rawline)
  buffer.writefmt(state.fmtline)
  buffer.writeraw(state.rawline)
  state.x = 0
  inc state.y
  state.nextspaces = 0
  state.fmtline = ""
  state.rawline = ""

proc addSpaces(buffer: Buffer, state: var RenderState, n: int) =
  if state.x + n > buffer.width:
    buffer.flushLine(state)
    return
  state.blankspaces += n
  state.write(' '.repeat(n))
  state.x += n

proc writeWrappedText(buffer: Buffer, state: var RenderState, node: Node) =
  state.lastwidth = 0
  var n = 0
  var fmtword = ""
  var rawword = ""
  var prevl = false
  let fmttext = node.getFmtText()
  for w in fmttext:
    if w.len > 0 and w[0] == '\e':
      fmtword &= w
      continue

    for r in w.runes:
      if r == Rune(' '):
        if rawword.len > 0 and rawword[0] == ' ' and prevl:
          fmtword = fmtword.substr(1)
          rawword = rawword.substr(1)
          state.x -= 1
          prevl = false
        state.write(fmtword, rawword)
        fmtword = ""
        rawword = ""

      if r == Rune('\n'):
        state.write(fmtword, rawword)
        buffer.flushLine(state)
        rawword = ""
        fmtword = ""
      else:
        fmtword &= r
        rawword &= r

      state.x += r.width()

      if state.x >= buffer.width:
        state.lastwidth = max(state.lastwidth, state.x)
        buffer.flushLine(state)
        state.x = rawword.width()
        prevl = true
      else:
        state.lastwidth = max(state.lastwidth, state.x)

      inc n

  state.write(fmtword, rawword)
  if prevl:
    state.x += rawword.width()
    prevl = false

  state.lastwidth = max(state.lastwidth, state.x)

proc preAlignNode(buffer: Buffer, node: Node, state: var RenderState) =
  let style = node.getStyle()
  if state.rawline.len > 0 and node.firstNode() and state.blanklines == 0:
    buffer.flushLine(state)

  if node.firstNode():
    #while state.blanklines < max(style.margin, style.margintop):
    #  buffer.flushLine(state)
    state.indent += style.indent

  if state.rawline.len > 0 and state.blanklines == 0 and node.displayed():
    buffer.addSpaces(state, state.nextspaces)
    state.nextspaces = 0
    #if state.blankspaces < max(style.margin, style.marginleft):
    #  buffer.addSpaces(state, max(style.margin, style.marginleft) - state.blankspaces)

  if style.centered and state.rawline.len == 0 and node.displayed():
    buffer.addSpaces(state, max(buffer.width div 2 - state.centerlen div 2, 0))
    state.centerlen = 0
  
  if node.isElemNode() and style.display == DISPLAY_LIST_ITEM and state.indent > 0:
    if state.blanklines == 0:
      buffer.flushLine(state)
    var listchar = "•"
    #case elem.parentElement.tagType
    #of TAG_UL:
    #  listchar = "•"
    #of TAG_OL:
    #  inc state.listval
    #  listchar = $state.listval & ")"
    #else:
    #  return
    buffer.addSpaces(state, state.indent)
    state.write(listchar)
    state.x += listchar.runeLen()
    buffer.addSpaces(state, 1)

proc postAlignNode(buffer: Buffer, node: Node, state: var RenderState) =
  let style = node.getStyle()

  if node.getRawLen() > 0:
    state.blanklines = 0
    state.blankspaces = 0

  #if state.rawline.len > 0 and state.blanklines == 0:
  #  state.nextspaces += max(style.margin, style.marginright)
  #  if node.lastNode() and (node.isTextNode() or elem.childNodes.len == 0):
  #    buffer.flushLine(state)

  if node.lastNode():
    #while state.blanklines < max(style.margin, style.marginbottom):
    #  buffer.flushLine(state)
    state.indent -= style.indent

  if style.display == DISPLAY_LIST_ITEM and node.lastNode():
    buffer.flushLine(state)

proc renderNode(buffer: Buffer, node: Node, state: var RenderState) =
  if not (node.nodeType in {ELEMENT_NODE, TEXT_NODE}):
    return
  let style = node.getStyle()
  if node.nodeType == ELEMENT_NODE:
    if Element(node).tagType in {TAG_SCRIPT, TAG_STYLE, TAG_NOSCRIPT, TAG_TITLE}:
      return
  if style.hidden or style.display == DISPLAY_NONE: return
  if node.nodeType == ELEMENT_NODE:
    state.lastelem = (Element)node
  else:
    state.lastelem = node.parentElement

  if not state.docenter:
    if style.centered:
      state.centerqueue.add(node)
      if node.lastNode():
        state.docenter = true
        state.centerlen = 0
        for node in state.centerqueue:
          state.centerlen += node.getRawLen()
        for node in state.centerqueue:
          buffer.renderNode(node, state)
        state.centerqueue.setLen(0)
        state.docenter = false
        return
      else:
        return
    if state.centerqueue.len > 0:
      state.docenter = true
      state.centerlen = 0
      for node in state.centerqueue:
        state.centerlen += node.getRawLen()
      for node in state.centerqueue:
        buffer.renderNode(node, state)
      state.centerqueue.setLen(0)
      state.docenter = false

  buffer.preAlignNode(node, state)

  node.x = state.x
  node.y = state.y
  buffer.writeWrappedText(state, node)
  node.ex = state.x
  node.ey = state.y
  node.width = state.lastwidth - node.x - 1
  node.height = state.y - node.y + 1

  buffer.postAlignNode(node, state)

proc setLastHtmlLine(buffer: Buffer, state: var RenderState) =
  if state.rawline.len != 0:
    buffer.flushLine(state)

proc renderHtml*(buffer: Buffer) =
  var stack: seq[Node]
  let first = buffer.document.root
  stack.add(first)

  var state = newRenderState()
  while stack.len > 0:
    let currElem = stack.pop()
    buffer.renderNode(currElem, state)
    var i = currElem.childNodes.len - 1
    while i >= 0:
      stack.add(currElem.childNodes[i])
      i -= 1

  buffer.setLastHtmlLine(state)

proc drawHtml(buffer: Buffer) =
  var state = newRenderState()
  for node in buffer.nodes:
    buffer.renderNode(node, state)
  buffer.setLastHtmlLine(state)

proc statusMsgForBuffer(buffer: Buffer) =
  var msg = $(buffer.cursory + 1) & "/" & $(buffer.lastLine() + 1) & " (" &
            $buffer.atPercentOf() & "%) " &
            "<" & buffer.title & ">"
  if buffer.hovertext.len > 0:
    msg &= " " & buffer.hovertext
  statusMsg(msg.maxString(buffer.width), buffer.height)

proc cursorBufferPos(buffer: Buffer) =
  var x = max(buffer.cursorx - buffer.fromx, 0)
  var y = buffer.cursory - buffer.fromy
  termGoto(x, y)

proc displayBuffer(buffer: Buffer) =
  eraseScreen()
  termGoto(0, 0)

  print(buffer.generateFullOutput().ansiReset())

proc inputLoop(attrs: TermAttributes, buffer: Buffer): bool =
  var s = ""
  var feedNext = false
  while true:
    buffer.redraw = false
    stdout.showCursor()
    buffer.cursorBufferPos()
    if not feedNext:
      s = ""
    else:
      feedNext = false
    let c = getch()
    s &= c
    let action = getNormalAction(s)
    var redraw = false
    var reshape = false
    var nostatus = false
    case action
    of ACTION_QUIT:
      eraseScreen()
      setCursorPos(0, 0)
      return false
    of ACTION_CURSOR_LEFT: buffer.cursorLeft()
    of ACTION_CURSOR_DOWN: buffer.cursorDown()
    of ACTION_CURSOR_UP: buffer.cursorUp()
    of ACTION_CURSOR_RIGHT: buffer.cursorRight()
    of ACTION_CURSOR_LINEBEGIN: buffer.cursorLineBegin()
    of ACTION_CURSOR_LINEEND: buffer.cursorLineEnd()
    of ACTION_CURSOR_NEXT_WORD: buffer.cursorNextWord()
    of ACTION_CURSOR_PREV_WORD: buffer.cursorPrevWord()
    of ACTION_CURSOR_NEXT_LINK: buffer.cursorNextLink()
    of ACTION_CURSOR_PREV_LINK: buffer.cursorPrevLink()
    of ACTION_PAGE_DOWN: buffer.pageDown()
    of ACTION_PAGE_UP: buffer.pageUp()
    of ACTION_PAGE_RIGHT: buffer.pageRight()
    of ACTION_PAGE_LEFT: buffer.pageLeft()
    of ACTION_HALF_PAGE_DOWN: buffer.halfPageDown()
    of ACTION_HALF_PAGE_UP: buffer.halfPageUp()
    of ACTION_CURSOR_FIRST_LINE: buffer.cursorFirstLine()
    of ACTION_CURSOR_LAST_LINE: buffer.cursorLastLine()
    of ACTION_CURSOR_TOP: buffer.cursorTop()
    of ACTION_CURSOR_MIDDLE: buffer.cursorMiddle()
    of ACTION_CURSOR_BOTTOM: buffer.cursorBottom()
    of ACTION_CENTER_LINE: buffer.centerLine()
    of ACTION_SCROLL_DOWN: buffer.scrollDown()
    of ACTION_SCROLL_UP: buffer.scrollUp()
    of ACTION_SCROLL_LEFT: buffer.scrollLeft()
    of ACTION_SCROLL_RIGHT: buffer.scrollRight()
    of ACTION_CLICK:
      discard
    of ACTION_CHANGE_LOCATION:
      var url = $buffer.location

      clearStatusMsg(buffer.height)
      let status = readLine("URL: ", url, buffer.width)
      if status:
        buffer.setLocation(parseUri(url))
        return true
    of ACTION_LINE_INFO:
      statusMsg("line " & $buffer.cursory & "/" & $buffer.lastLine() & " col " & $(buffer.cursorx + 1) & "/" & $buffer.currentLineWidth(), buffer.width)
      nostatus = true
    of ACTION_FEED_NEXT:
      feedNext = true
    of ACTION_RELOAD: return true
    of ACTION_RESHAPE:
      reshape = true
      redraw = true
    of ACTION_REDRAW: redraw = true
    else: discard
    stdout.hideCursor()

    if buffer.refreshTermAttrs():
      redraw = true
      reshape = true

    if buffer.redraw:
      redraw = true

    if reshape:
      buffer.reshape()
    if redraw:
      buffer.refreshDisplay()
      buffer.displayBuffer()

    if not nostatus:
      buffer.statusMsgForBuffer()
    else:
      nostatus = false

proc displayPage*(attrs: TermAttributes, buffer: Buffer): bool =
  #buffer.printwrite = true
  discard buffer.gotoAnchor()
  buffer.displayBuffer()
  buffer.statusMsgForBuffer()
  return inputLoop(attrs, buffer)


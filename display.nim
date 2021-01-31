import terminal
import options
import uri
import strutils
import unicode

import fusion/htmlparser/xmltree

import buffer
import termattrs
import htmlelement
import twtstr
import twtio
import config
import enums

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
    centerqueue: seq[HtmlNode]
    centerlen: int
    blanklines: int
    blankspaces: int
    nextspaces: int
    docenter: bool
    indent: int
    listval: int

func newRenderState(): RenderState =
  return RenderState()

proc write(state: var RenderState, s: string) =
  state.fmtline &= s
  state.rawline &= s

proc write(state: var RenderState, fs: string, rs: string) =
  state.fmtline &= fs
  state.rawline &= rs

proc flushLine(buffer: Buffer, state: var RenderState) =
  if state.rawline.len == 0:
    inc state.blanklines
  assert(state.rawline.runeLen() < buffer.width, "line too long:\n" & state.rawline)
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

proc writeWrappedText(buffer: Buffer, state: var RenderState, node: HtmlNode) =
  state.lastwidth = 0
  var n = 0
  var fmtword = ""
  var rawword = ""
  var prevl = false
  for w in node.fmttext:
    if w.len > 0 and w[0] == '\e':
      fmtword &= w
      continue

    for r in w.runes:
      if r == Rune(' '):
        if rawword[0] == ' ' and prevl: #first byte can't fool comparison to ascii
          fmtword = fmtword.substr(1)
          rawword = rawword.substr(1)
          state.x -= 1
          prevl = false
        state.write(fmtword, rawword)
        fmtword = ""
        rawword = ""

      fmtword &= r
      rawword &= r

      state.x += mk_wcwidth_cjk(r)

      if state.x >= buffer.width:
        state.lastwidth = max(state.lastwidth, state.x)
        buffer.flushLine(state)
        state.x = mk_wcswidth_cjk(rawword)
        prevl = true
      else:
        state.lastwidth = max(state.lastwidth, state.x)

      inc n

  state.write(fmtword, rawword)
  if prevl:
    state.x += mk_wcswidth_cjk(rawword)
    prevl = false

  state.lastwidth = max(state.lastwidth, state.x)

proc preAlignNode(buffer: Buffer, node: HtmlNode, state: var RenderState) =
  let elem = node.nodeAttr()
  if state.rawline.len > 0 and node.openblock and state.blanklines == 0:
    buffer.flushLine(state)

  if node.openblock:
    while state.blanklines < max(elem.margin, elem.margintop):
      buffer.flushLine(state)
    state.indent += elem.indent

  if state.rawline.len > 0 and state.blanklines == 0 and node.displayed():
    buffer.addSpaces(state, state.nextspaces)
    state.nextspaces = 0
    if state.blankspaces < max(elem.margin, elem.marginleft):
      buffer.addSpaces(state, max(elem.margin, elem.marginleft) - state.blankspaces)

  if elem.centered and state.rawline.len == 0 and node.displayed():
    buffer.addSpaces(state, max(buffer.width div 2 - state.centerlen div 2, 0))
    state.centerlen = 0
  
  if node.isElemNode() and elem.display == DISPLAY_LIST_ITEM and state.indent > 0:
    buffer.flushLine(state)
    var listchar = ""
    case elem.parentElement.tagType
    of TAG_UL:
      listchar = "•"
    of TAG_OL:
      inc state.listval
      listchar = $state.listval & ")"
    else:
      return
    buffer.addSpaces(state, state.indent)
    state.write(listchar)
    state.x += listchar.runeLen()
    buffer.addSpaces(state, 1)

proc postAlignNode(buffer: Buffer, node: HtmlNode, state: var RenderState) =
  let elem = node.nodeAttr()

  if node.getRawLen() > 0:
    state.blanklines = 0
    state.blankspaces = 0

  if state.rawline.len > 0 and state.blanklines == 0:
    state.nextspaces += max(elem.margin, elem.marginright)
    if node.closeblock and (node.isTextNode() or elem.numChildNodes == 0):
      state.write($node.nodeAttr().tagType)
      buffer.flushLine(state)

  if node.closeblock:
    while state.blanklines < max(elem.margin, elem.marginbottom):
      buffer.flushLine(state)
    if node.isElemNode():
      state.indent -= elem.indent

  if elem.tagType == TAG_BR and not node.openblock:
    buffer.flushLine(state)

proc renderNode(buffer: Buffer, node: HtmlNode, state: var RenderState) =
  if node.isDocument():
    return
  let elem = node.nodeAttr()
  if elem.tagType == TAG_TITLE:
    if node.isTextNode():
      buffer.title = node.rawtext
    return
  else: discard
  if elem.hidden: return

  if not state.docenter:
    if elem.centered:
      state.centerqueue.add(node)
      if node.closeblock or elem.tagType == TAG_BR:
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

iterator revItems*(n: XmlNode): XmlNode {.inline.} =
  var i = n.len - 1
  while i >= 0:
    if n[i].kind != xnComment:
      yield n[i]
    i -= 1

type
  XmlHtmlNode* = ref XmlHtmlNodeObj
  XmlHtmlNodeObj = object
    xml*: XmlNode
    html*: HtmlNode

proc setLastHtmlLine(buffer: Buffer, state: var RenderState) =
  if state.rawline.len != 0:
    buffer.flushLine(state)

proc renderHtml*(buffer: Buffer) =
  var stack: seq[XmlHtmlNode]
  let first = XmlHtmlNode(xml: buffer.htmlSource,
                         html: getHtmlNode(buffer.htmlSource, buffer.document))
  stack.add(first)

  var state = newRenderState()
  while stack.len > 0:
    let currElem = stack.pop()
    buffer.addNode(currElem.html)
    buffer.renderNode(currElem.html, state)
    if currElem.xml.len > 0:
      var last = false
      for item in currElem.xml.revItems:
        let child = XmlHtmlNode(xml: item,
                                html: getHtmlNode(item, currElem.html))
        stack.add(child)
        currElem.html.childNodes.add(child.html)
        if not last and not child.html.hidden:
          last = true
          if HtmlElement(currElem.html).display == DISPLAY_BLOCK:
            eprint "elem", HtmlElement(currElem.html).tagType, "close @", child.html.nodeAttr().tagType
            stack[^1].html.closeblock = true
      if last:
        eprint "elem", HtmlElement(currElem.html).tagType, "open @", stack[^1].html.nodeAttr().tagType
        if HtmlElement(currElem.html).display == DISPLAY_BLOCK:
          stack[^1].html.openblock = true
  buffer.setLastHtmlLine(state)

proc nrenderHtml*(buffer: Buffer) =
  var stack: seq[HtmlNode]
  let first = buffer.document
  stack.add(first)

  var state = newRenderState()
  while stack.len > 0:
    let currElem = stack.pop()
    buffer.addNode(currElem)
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
  var x = buffer.cursorx
  var y = buffer.cursory - 1 - buffer.fromY
  termGoto(x, y + 1)

proc displayBuffer(buffer: Buffer) =
  eraseScreen()
  termGoto(0, 0)

  print(buffer.visibleText().ansiReset())

proc inputLoop(attrs: TermAttributes, buffer: Buffer): bool =
  var s = ""
  var feedNext = false
  while true:
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
      return false
    of ACTION_CURSOR_LEFT: redraw = buffer.cursorLeft()
    of ACTION_CURSOR_DOWN: redraw = buffer.cursorDown()
    of ACTION_CURSOR_UP: redraw = buffer.cursorUp()
    of ACTION_CURSOR_RIGHT: redraw = buffer.cursorRight()
    of ACTION_CURSOR_LINEBEGIN: buffer.cursorLineBegin()
    of ACTION_CURSOR_LINEEND: buffer.cursorLineEnd()
    of ACTION_CURSOR_NEXT_WORD: redraw = buffer.cursorNextWord()
    of ACTION_CURSOR_PREV_WORD: redraw = buffer.cursorPrevWord()
    of ACTION_CURSOR_NEXT_LINK: redraw = buffer.cursorNextLink()
    of ACTION_CURSOR_PREV_LINK: redraw = buffer.cursorPrevLink()
    of ACTION_PAGE_DOWN: redraw = buffer.pageDown()
    of ACTION_PAGE_UP: redraw = buffer.pageUp()
    of ACTION_HALF_PAGE_DOWN: redraw = buffer.halfPageDown()
    of ACTION_HALF_PAGE_UP: redraw = buffer.halfPageUp()
    of ACTION_CURSOR_FIRST_LINE: redraw = buffer.cursorFirstLine()
    of ACTION_CURSOR_LAST_LINE: redraw = buffer.cursorLastLine()
    of ACTION_CURSOR_TOP: redraw = buffer.cursorTop()
    of ACTION_CURSOR_MIDDLE: redraw = buffer.cursorMiddle()
    of ACTION_CURSOR_BOTTOM: redraw = buffer.cursorBottom()
    of ACTION_CENTER_LINE: redraw = buffer.centerLine()
    of ACTION_SCROLL_DOWN: redraw = buffer.scrollDown()
    of ACTION_SCROLL_UP: redraw = buffer.scrollUp()
    of ACTION_CLICK:
      let selectedElem = buffer.findSelectedElement()
      if selectedElem.isSome:
        case selectedElem.get().tagType
        of TAG_INPUT:
          clearStatusMsg(buffer.height)
          let status = readLine("TEXT:", HtmlInputElement(selectedElem.get()).value)
          if status:
            reshape = true
            redraw = true
        else: discard
        if selectedElem.get().islink:
          let anchor = HtmlAnchorElement(buffer.selectedlink.ancestor(TAG_A)).href
          buffer.gotoLocation(parseUri(anchor))
          return true
    of ACTION_CHANGE_LOCATION:
      var url = $buffer.document.location

      clearStatusMsg(buffer.height)
      let status = readLine("URL:", url)
      if status:
        buffer.setLocation(parseUri(url))
        return true
    of ACTION_LINE_INFO:
      statusMsg("line " & $buffer.cursory & "/" & $buffer.lastLine() & " col " & $buffer.cursorx & "/" & $buffer.realCurrentLineLength(), buffer.width)
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

    let prevlink = buffer.selectedlink
    let sel = buffer.checkLinkSelection()
    if sel:
      buffer.clearText()
      buffer.drawHtml()
      termGoto(0, buffer.selectedlink.y - buffer.fromy)
      stdout.eraseLine()
      for i in buffer.selectedlink.y..buffer.selectedlink.ey:
        if i < buffer.fromy + buffer.height - 1:
          let line = buffer.fmttext[i]
          print(line)
          print('\n')
      print("".ansiReset())
    
    if prevlink != nil:
      buffer.clearText()
      buffer.drawHtml()
      termGoto(0, prevlink.y - buffer.fromy)
      for i in prevlink.y..prevlink.ey:
        if i < buffer.fromy + buffer.height - 1:
          let line = buffer.fmttext[i]
          stdout.eraseLine()
          print(line)
          print('\n')
      print("".ansiReset())

    if buffer.refreshTermAttrs():
      redraw = true
      reshape = true

    if reshape:
      buffer.clearText()
      buffer.drawHtml()
    if redraw:
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


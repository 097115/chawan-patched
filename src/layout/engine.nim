import unicode

import layout/box
import types/enums
import html/dom
import css/values
import utils/twtstr

func newInlineContext*(box: CSSBox): InlineContext =
  new(result)
  result.fromx = box.x
  result.whitespace = true
  result.ws_initial = true

func newBlockContext(): BlockContext =
  new(result)

proc flushLines(box: CSSBox) =
  if box.icontext.conty:
    inc box.height
    inc box.icontext.fromy
    inc box.bcontext.fromy
    box.icontext.conty = false
  box.icontext.fromy += box.bcontext.margin_todo
  box.bcontext.margin_done += box.bcontext.margin_todo
  box.bcontext.margin_todo = 0

func newBlockBox(state: var LayoutState, parent: CSSBox, vals: CSSComputedValues): CSSBlockBox =
  new(result)
  result.x = parent.x
  result.bcontext = newBlockContext()

  parent.flushLines()

  let mtop = vals[PROPERTY_MARGIN_TOP].length.cells()
  if mtop > parent.bcontext.margin_done:
    let diff = mtop - parent.bcontext.margin_done
    parent.icontext.fromy += diff
    parent.bcontext.margin_done += diff

  result.y = parent.icontext.fromy

  result.bcontext.margin_done = parent.bcontext.margin_done

  result.width = parent.width
  result.icontext = newInlineContext(parent)
  result.icontext.fromy = result.y
  result.cssvalues = vals

func newInlineBox*(parent: CSSBox, vals: CSSComputedValues): CSSInlineBox =
  assert parent != nil
  new(result)
  result.x = parent.x
  result.y = parent.icontext.fromy

  result.width = parent.width
  result.icontext = parent.icontext
  result.bcontext = parent.bcontext
  result.cssvalues = vals

type InlineState = object
  ibox: CSSInlineBox
  rowi: int
  rowbox: CSSRowBox
  word: seq[Rune]
  ww: int
  skip: bool
  nodes: seq[Node]

func fromx(state: InlineState): int = state.ibox.icontext.fromx
func fromy(state: InlineState): int = state.ibox.icontext.fromy
func width(state: InlineState): int = state.rowbox.width

proc newRowBox(state: var InlineState) =
  state.rowbox = CSSRowBox()
  state.rowbox.x = state.fromx
  state.rowbox.y = state.fromy + state.rowi

  let cssvalues = state.ibox.cssvalues
  state.rowbox.color = cssvalues[PROPERTY_COLOR].color
  state.rowbox.fontstyle = cssvalues[PROPERTY_FONT_STYLE].fontstyle
  state.rowbox.fontweight = cssvalues[PROPERTY_FONT_WEIGHT].integer
  state.rowbox.textdecoration = cssvalues[PROPERTY_TEXT_DECORATION].textdecoration
  state.rowbox.nodes = state.nodes

proc inlineWrap(state: var InlineState) =
  state.ibox.content.add(state.rowbox)
  inc state.rowi
  state.ibox.icontext.fromx = state.ibox.x
  if state.word.len == 0:
    state.ibox.icontext.whitespace = true
    state.ibox.icontext.ws_initial = true
    state.ibox.icontext.conty = false
  else:
    if state.word[^1] == Rune(' '):
      state.ibox.icontext.whitespace = true
      state.ibox.icontext.ws_initial = false
    state.ibox.icontext.conty = true
  #eprint "wrap", state.rowbox.y, state.rowbox.str
  state.newRowBox()

proc addWord(state: var InlineState) =
  state.rowbox.str &= $state.word
  state.rowbox.width += state.ww
  state.word.setLen(0)
  state.ww = 0

proc wrapNormal(state: var InlineState, r: Rune) =
  if state.fromx + state.width + state.ww == state.ibox.width and r == Rune(' '):
    state.addWord()
  if state.word.len == 0:
    if r == Rune(' '):
      state.skip = true
  elif state.word[0] == Rune(' '):
    state.word = state.word.substr(1)
    dec state.ww
  state.inlineWrap()
  if not state.skip and r == Rune(' '):
    state.ibox.icontext.whitespace = true
    state.ibox.icontext.ws_initial = false

proc checkWrap(state: var InlineState, r: Rune) =
  if state.ibox.cssvalues[PROPERTY_WHITESPACE].whitespace in {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
    return
  case state.ibox.cssvalues[PROPERTY_WORD_BREAK].wordbreak
  of WORD_BREAK_NORMAL:
    if state.fromx + state.width > state.ibox.x and
        state.fromx + state.width + state.ww + r.width() > state.ibox.width:
      state.wrapNormal(r)
  of WORD_BREAK_BREAK_ALL:
    if state.fromx + state.width + state.ww + r.width() > state.ibox.width:
      var pl: seq[Rune]
      var i = 0
      var w = 0
      while i < state.word.len and
          state.ibox.icontext.fromx + state.rowbox.width + w <
            state.ibox.width:
        pl &= state.word[i]
        w += state.word[i].width()
        inc i

      if pl.len > 0:
        state.rowbox.str &= $pl
        state.rowbox.width += w
        state.word = state.word.substr(pl.len)
        state.ww = state.word.width()
      if r == Rune(' '):
        state.skip = true
      state.inlineWrap()
  of WORD_BREAK_KEEP_ALL:
    if state.fromx + state.width > state.ibox.x and
        state.fromx + state.width + state.ww + r.width() > state.ibox.width:
      state.wrapNormal(r)

proc preWrap(state: var InlineState) =
  state.inlineWrap()
  state.ibox.icontext.whitespace = false
  state.ibox.icontext.ws_initial = true
  state.skip = true

proc processInlineBox(lstate: var LayoutState, parent: CSSBox, str: string): CSSBox =
  if str.len > 0:
    parent.icontext.fromy += parent.bcontext.margin_todo
    parent.bcontext.margin_done += parent.bcontext.margin_todo
    parent.bcontext.margin_todo = 0

  var state: InlineState
  state.nodes = lstate.nodes
  var use_parent = false
  if parent of CSSInlineBox:
    state.ibox = CSSInlineBox(parent)
    use_parent = true
  else:
    state.ibox = newInlineBox(parent, parent.cssvalues)

  if str.len == 0:
    return

  var i = 0
  state.newRowBox()

  var r: Rune
  while i < str.len:
    var rw = 0
    case str[i]
    of ' ', '\n', '\t':
      rw = 1
      r = Rune(str[i])
      inc i
      state.addWord()

      case state.ibox.cssvalues[PROPERTY_WHITESPACE].whitespace
      of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
        if state.ibox.icontext.whitespace:
          if state.ibox.icontext.ws_initial:
            state.ibox.icontext.ws_initial = false
            state.skip = true
          else:
            state.skip = true
        state.ibox.icontext.whitespace = true
      of WHITESPACE_PRE_LINE:
        if state.ibox.icontext.whitespace:
          state.skip = true
        state.ibox.icontext.ws_initial = false
        if r == Rune('\n'):
          state.preWrap()
      of WHITESPACE_PRE, WHITESPACE_PRE_WRAP:
        state.ibox.icontext.ws_initial = false
        if r == Rune('\n'):
          state.preWrap()
      r = Rune(' ')
    else:
      state.ibox.icontext.whitespace = false
      fastRuneAt(str, i, r)
      rw = r.width()

    #TODO a better line wrapping algorithm would be nice
    if rw > 1 and state.ibox.cssvalues[PROPERTY_WORD_BREAK].wordbreak != WORD_BREAK_KEEP_ALL:
      state.addWord()

    state.checkWrap(r)

    if state.skip:
      state.skip = false
      continue

    state.word &= r
    state.ww += rw

  state.addWord()
  #eprint "write", state.rowbox.y, state.rowbox.str

  if state.rowbox.str.len > 0:
    state.ibox.content.add(state.rowbox)
    state.ibox.icontext.fromx += state.rowbox.width
    state.ibox.icontext.conty = true

  state.ibox.height += state.rowi
  if state.rowi > 0 or state.rowbox.width > 0:
    state.ibox.bcontext.margin_todo = 0
    state.ibox.bcontext.margin_done = 0
  state.ibox.icontext.fromy += state.rowi
  if use_parent:
    return nil
  return state.ibox

proc add(state: var LayoutState, parent: CSSBox, box: CSSBox) =
  if box == nil:
    return
  if box of CSSBlockBox:
    parent.icontext.fromx = parent.x
    parent.icontext.whitespace = true
    parent.icontext.ws_initial = true

    box.flushLines()

    let mbot = box.cssvalues[PROPERTY_MARGIN_BOTTOM].length.cells()
    parent.bcontext.margin_todo += mbot

    parent.bcontext.margin_done = box.bcontext.margin_done
    parent.bcontext.margin_todo = max(parent.bcontext.margin_todo - box.bcontext.margin_done, 0)

    #eprint "END", CSSBlockBox(box).tag, box.icontext.fromy
  parent.height += box.height
  parent.icontext.fromy = box.icontext.fromy
  parent.children.add(box)

proc processElemBox(state: var LayoutState, parent: CSSBox, elem: Element): CSSBox =
  if elem.tagType == TAG_BR:
    if parent.icontext.conty:
      #eprint "CONTY A"
      inc parent.height
      inc parent.icontext.fromy
      parent.icontext.conty = false
    else:
      inc parent.icontext.fromy
    parent.icontext.fromx = parent.x
  case elem.cssvalues[PROPERTY_DISPLAY].display
  of DISPLAY_BLOCK:
    #eprint "START", elem.tagType, parent.icontext.fromy
    result = state.newBlockBox(parent, elem.cssvalues)
  of DISPLAY_INLINE:
    #TODO anonymous block boxes
    result = newInlineBox(parent, elem.cssvalues)
  of DISPLAY_NONE:
    return nil
  else:
    return nil

proc processNodes(state: var LayoutState, parent: CSSBox, node: Node)

proc processNode(state: var LayoutState, parent: CSSBox, node: Node): CSSBox =
  case node.nodeType
  of ELEMENT_NODE:
    result = state.processElemBox(parent, Element(node))
    if result == nil:
      return
    state.processNodes(result, node)
  of TEXT_NODE:
    let text = Text(node)
    result = state.processInlineBox(parent, text.data)
  else: discard

proc processNodes(state: var LayoutState, parent: CSSBox, node: Node) =
  state.nodes.add(node)
  for c in node.childNodes:
    state.add(parent, state.processNode(parent, c))
  discard state.nodes.pop()

proc alignBoxes*(document: Document, width: int, height: int): CSSBox =
  var state: LayoutState
  var rootbox = CSSBlockBox(x: 0, y: 0, width: width, height: 0)
  rootbox.icontext = newInlineContext(rootbox)
  rootbox.bcontext = newBlockContext()
  state.nodes.add(document.root)
  state.processNodes(rootbox, document.root)
  return rootbox

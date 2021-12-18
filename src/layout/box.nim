import options

import css/values
import html/dom
import io/term

type
  BoxType* = enum
    INLINE, BLOCK, INLINE_BLOCK

  CSSRect* = object
    x1*: int
    y1*: int
    x2*: int
    y2*: int

  CSSBox* = ref object of RootObj
    t*: BoxType
    x*: int
    y*: int
    children*: seq[CSSBox]
    icontext*: InlineContext
    bcontext*: BlockContext
    cssvalues*: CSSSpecifiedValues
    node*: Node

  RowContainer* = object
    case leaf*: bool
    of true: row*: CSSRowBox
    of false: ctx*: InlineContext

  InlineContext* = ref object
    fromx*: int
    fromy*: int
    conty*: bool
    whitespace*: bool
    ws_initial*: bool
    conts*: seq[RowContainer]
    rows*: seq[CSSRowBox]

  BlockContext* = ref object
    fromy*: int
    margin_done*: int
    margin_todo*: int
    width*: int
    height*: Option[int]

  LayoutState* = object
    nodes*: seq[Node]
    term*: TermAttributes

  CSSRowBox* = object
    x*: int
    y*: int
    width*: int
    height*: int
    color*: CSSColor
    fontstyle*: CSSFontStyle
    fontweight*: int
    textdecoration*: CSSTextDecoration
    str*: string
    nodes*: seq[Node]

  CSSInlineBox* = ref object of CSSBox
  CSSBlockBox* = ref object of CSSBox
  CSSInlineBlockBox* = ref object of CSSBox

import std/algorithm
import std/math
import std/options
import std/unicode

import css/cssvalues
import css/stylednode
import img/bitmap
import layout/box
import layout/layoutunit
import types/winattrs
import utils/luwrap
import utils/strwidth
import utils/twtstr
import utils/widthconv

type
  LayoutState = ref object
    attrsp: ptr WindowAttributes
    positioned: seq[AvailableSpace]
    myRootProperties: CSSComputedValues

  # min-content: box width is longest word's width
  # max-content: box width is content width without wrapping
  # stretch: box width is n px wide
  # fit-content: also known as shrink-to-fit, box width is
  #   min(max-content, stretch(availableWidth))
  #   in other words, as wide as needed, but wrap if wider than allowed
  # (note: I write width here, but it can apply for any constraint)
  SizeConstraintType = enum
    scStretch, scFitContent, scMinContent, scMaxContent

  SizeConstraint = object
    t: SizeConstraintType
    u: LayoutUnit

  AvailableSpace = array[DimensionType, SizeConstraint]

  MinMaxSpan = object
    min: LayoutUnit
    max: LayoutUnit

  ResolvedSizes = object
    margin: RelativeRect
    padding: RelativeRect
    positioned: RelativeRect
    space: AvailableSpace
    minMaxSizes: array[DimensionType, MinMaxSpan]

const DefaultSpan = MinMaxSpan(min: 0, max: LayoutUnit.high)

proc `minWidth=`(sizes: var ResolvedSizes; w: LayoutUnit) =
  sizes.minMaxSizes[dtHorizontal].min = w

proc `maxWidth=`(sizes: var ResolvedSizes; w: LayoutUnit) =
  sizes.minMaxSizes[dtHorizontal].max = w

proc `minHeight=`(sizes: var ResolvedSizes; h: LayoutUnit) =
  sizes.minMaxSizes[dtVertical].min = h

proc `maxHeight=`(sizes: var ResolvedSizes; h: LayoutUnit) =
  sizes.minMaxSizes[dtVertical].max = h

func dimSum(rect: RelativeRect; dim: DimensionType): LayoutUnit =
  case dim
  of dtHorizontal: return rect.left + rect.right
  of dtVertical: return rect.top + rect.bottom

func dimStart(rect: RelativeRect; dim: DimensionType): LayoutUnit =
  case dim
  of dtHorizontal: return rect.left
  of dtVertical: return rect.top

func opposite(dim: DimensionType): DimensionType =
  case dim
  of dtHorizontal: return dtVertical
  of dtVertical: return dtHorizontal

func availableSpace(w, h: SizeConstraint): AvailableSpace =
  return [dtHorizontal: w, dtVertical: h]

func w(space: AvailableSpace): SizeConstraint {.inline.} =
  return space[dtHorizontal]

func w(space: var AvailableSpace): var SizeConstraint {.inline.} =
  return space[dtHorizontal]

func `w=`(space: var AvailableSpace; w: SizeConstraint) {.inline.} =
  space[dtHorizontal] = w

func h(space: var AvailableSpace): var SizeConstraint {.inline.} =
  return space[dtVertical]

func h(space: AvailableSpace): SizeConstraint {.inline.} =
  return space[dtVertical]

func `h=`(space: var AvailableSpace; h: SizeConstraint) {.inline.} =
  space[dtVertical] = h

template attrs(state: LayoutState): WindowAttributes =
  state.attrsp[]

func maxContent(): SizeConstraint =
  return SizeConstraint(t: scMaxContent)

func stretch(u: LayoutUnit): SizeConstraint =
  return SizeConstraint(t: scStretch, u: u)

func fitContent(u: LayoutUnit): SizeConstraint =
  return SizeConstraint(t: scFitContent, u: u)

type
  BoxBuilder = ref object of RootObj
    children: seq[BoxBuilder]
    computed: CSSComputedValues
    node: StyledNode

  InlineBoxBuilder = ref object of BoxBuilder
    text: seq[string]
    newline: bool
    splitType: set[SplitType]
    bmp: Bitmap

  BlockBoxBuilder = ref object of BoxBuilder
    inlinelayout: bool

  MarkerBoxBuilder = ref object of InlineBoxBuilder

  ListItemBoxBuilder = ref object of BoxBuilder
    marker: MarkerBoxBuilder
    content: BlockBoxBuilder

  TableRowGroupBoxBuilder = ref object of BlockBoxBuilder

  TableRowBoxBuilder = ref object of BlockBoxBuilder

  TableCellBoxBuilder = ref object of BlockBoxBuilder

  TableBoxBuilder = ref object of BlockBoxBuilder
    rowgroups: seq[TableRowGroupBoxBuilder]

  TableCaptionBoxBuilder = ref object of BlockBoxBuilder

func fitContent(sc: SizeConstraint): SizeConstraint =
  case sc.t
  of scMinContent, scMaxContent:
    return sc
  of scStretch, scFitContent:
    return SizeConstraint(t: scFitContent, u: sc.u)

func isDefinite(sc: SizeConstraint): bool =
  return sc.t in {scStretch, scFitContent}

# Layout (2nd pass)
func px(l: CSSLength; lctx: LayoutState; p: LayoutUnit = 0):
    LayoutUnit {.inline.} =
  return px(l, lctx.attrs, p)

func px(l: CSSLength; lctx: LayoutState; p: Option[LayoutUnit]):
    Option[LayoutUnit] {.inline.} =
  if l.unit == cuPerc and p.isNone:
    return none(LayoutUnit)
  return some(px(l, lctx.attrs, p.get(0)))

func canpx(l: CSSLength; sc: SizeConstraint): bool =
  return not l.auto and (l.unit != cuPerc or sc.isDefinite())

func canpx(l: CSSLength; p: Option[LayoutUnit]): bool =
  return not l.auto and (l.unit != cuPerc or p.isSome)

# Note: for margins only
# For percentages, use 0 for indefinite, and containing box's size for
# definite.
func px(l: CSSLength; lctx: LayoutState; p: SizeConstraint): LayoutUnit =
  if l.unit == cuPerc:
    case p.t
    of scMinContent, scMaxContent:
      return 0
    of scStretch, scFitContent:
      return l.px(lctx, p.u)
  return px(l, lctx.attrs, 0)

func stretchOrMaxContent(l: CSSLength; lctx: LayoutState; sc: SizeConstraint):
    SizeConstraint =
  if l.canpx(sc):
    return stretch(l.px(lctx, sc))
  return maxContent()

func applySizeConstraint(u: LayoutUnit; availableSize: SizeConstraint):
    LayoutUnit =
  case availableSize.t
  of scStretch:
    return availableSize.u
  of scMinContent, scMaxContent:
    # must be calculated elsewhere...
    return u
  of scFitContent:
    return min(u, availableSize.u)

type
  BlockContext = object
    lctx: LayoutState
    marginTodo: Strut
    # We use a linked list to set the correct BFC offset and relative offset
    # for every block with an unresolved y offset on margin resolution.
    # marginTarget is a pointer to the last un-resolved ancestor.
    # ancestorsHead is a pointer to the last element of the ancestor list
    # (which may in fact be a pointer to the BPS of a previous sibling's
    # child).
    # parentBps is a pointer to the currently layouted parent block's BPS.
    marginTarget: BlockPositionState
    ancestorsHead: BlockPositionState
    parentBps: BlockPositionState
    exclusions: seq[Exclusion]
    unpositionedFloats: seq[UnpositionedFloat]
    maxFloatHeight: LayoutUnit
    clearOffset: LayoutUnit

  UnpositionedFloat = object
    parentBps: BlockPositionState
    space: AvailableSpace
    box: BlockBox

  BlockPositionState = ref object
    next: BlockPositionState
    box: BlockBox
    offset: Offset # offset relative to the block formatting context
    resolved: bool # has the position been resolved yet?

  Exclusion = object
    offset: Offset
    size: Size
    t: CSSFloat

  Strut = object
    pos: LayoutUnit
    neg: LayoutUnit

type
  LineBoxState = object
    atomstates: seq[InlineAtomState]
    baseline: LayoutUnit
    lineheight: LayoutUnit
    paddingTop: LayoutUnit
    paddingBottom: LayoutUnit
    line: LineBox
    availableWidth: LayoutUnit
    hasExclusion: bool
    charwidth: int
    # Set at the end of layoutText. It helps determine the beginning of the
    # next inline fragment.
    widthAfterWhitespace: LayoutUnit
    # minimum height to fit all inline atoms
    minHeight: LayoutUnit

  LineBox = ref object
    atoms: seq[InlineAtom]
    size: Size
    offsety: LayoutUnit # offset of line in root fragment
    height: LayoutUnit # height used for painting; does not include padding

  InlineAtomState = object
    vertalign: CSSVerticalAlign
    baseline: LayoutUnit
    marginTop: LayoutUnit
    marginBottom: LayoutUnit

  InlineContext = object
    root: RootInlineFragment
    bctx: ptr BlockContext
    bfcOffset: Offset
    currentLine: LineBoxState
    hasshy: bool
    lctx: LayoutState
    lines: seq[LineBox]
    minwidth: LayoutUnit
    space: AvailableSpace
    whitespacenum: int
    whitespaceIsLF: bool
    whitespaceFragment: InlineFragment
    word: InlineAtom
    wordstate: InlineAtomState
    wrappos: int # position of last wrapping opportunity, or -1
    firstTextFragment: InlineFragment
    lastTextFragment: InlineFragment

  InlineState = object
    computed: CSSComputedValues
    node: StyledNode
    fragment: InlineFragment
    firstLine: bool
    startOffsetTop: Offset
    # we do not want to collapse newlines over tag boundaries, so these are
    # in state
    lastrw: int # last rune width of the previous word
    firstrw: int # first rune width of the current word
    prevrw: int # last processed rune's width

func whitespacepre(computed: CSSComputedValues): bool =
  computed{"white-space"} in {WhitespacePre, WhitespacePreLine,
    WhitespacePreWrap}

func nowrap(computed: CSSComputedValues): bool =
  computed{"white-space"} in {WhitespaceNowrap, WhitespacePre}

func cellwidth(lctx: LayoutState): int =
  lctx.attrs.ppc

func cellwidth(ictx: InlineContext): int =
  ictx.lctx.cellwidth

func cellheight(lctx: LayoutState): int =
  lctx.attrs.ppl

func cellheight(ictx: InlineContext): int =
  ictx.lctx.attrs.ppl

template atoms(state: LineBoxState): untyped =
  state.line.atoms

template size(state: LineBoxState): untyped =
  state.line.size

template offsety(state: LineBoxState): untyped =
  state.line.offsety

func size(ictx: var InlineContext): var Size =
  ictx.root.size

# Whitespace between words
func computeShift(ictx: InlineContext; state: InlineState): LayoutUnit =
  if ictx.whitespacenum == 0:
    return 0
  if ictx.whitespaceIsLF and state.lastrw == 2 and state.firstrw == 2:
    # skip line feed between double-width characters
    return 0
  if not state.computed.whitespacepre:
    if ictx.currentLine.atoms.len == 0 or
        ictx.currentLine.atoms[^1].t == iatSpacing:
      return 0
  return ictx.cellwidth * ictx.whitespacenum

proc applyLineHeight(ictx: InlineContext; state: var LineBoxState;
    computed: CSSComputedValues) =
  let lctx = ictx.lctx
  #TODO this should be computed during cascading.
  let lineheight = if computed{"line-height"}.auto: # ergo normal
    lctx.cellheight.toLayoutUnit
  else:
    # Percentage: refers to the font size of the element itself.
    computed{"line-height"}.px(lctx, lctx.cellheight)
  let paddingTop = computed{"padding-top"}.px(lctx, ictx.space.w)
  let paddingBottom = computed{"padding-bottom"}.px(lctx, ictx.space.w)
  state.paddingTop = max(paddingTop, state.paddingTop)
  state.paddingBottom = max(paddingBottom, state.paddingBottom)
  state.lineheight = max(lineheight, state.lineheight)

proc newWord(ictx: var InlineContext; state: var InlineState) =
  ictx.word = InlineAtom(
    t: iatWord,
    size: size(w = 0, h = ictx.cellheight)
  )
  ictx.wordstate = InlineAtomState(
    vertalign: state.computed{"vertical-align"},
    baseline: ictx.cellheight
  )
  ictx.wrappos = -1
  ictx.hasshy = false

proc horizontalAlignLines(ictx: var InlineContext; state: InlineState) =
  let width = case ictx.space.w.t
  of scMinContent, scMaxContent:
    ictx.size.w
  of scFitContent:
    min(ictx.size.w, ictx.space.w.u)
  of scStretch:
    max(ictx.size.w, ictx.space.w.u)
  # we don't support directions for now so left = start and right = end
  case state.computed{"text-align"}
  of TextAlignStart, TextAlignLeft, TextAlignChaLeft, TextAlignJustify:
    discard
  of TextAlignEnd, TextAlignRight, TextAlignChaRight:
    # move everything
    for line in ictx.lines:
      let x = max(width, line.size.w) - line.size.w
      for atom in line.atoms:
        atom.offset.x += x
        ictx.size.w = max(atom.offset.x + atom.size.w, ictx.size.w)
  of TextAlignCenter, TextAlignChaCenter:
    # NOTE if we need line x offsets, use:
    #let width = width - line.offset.x
    for line in ictx.lines:
      let x = max((max(width, line.size.w)) div 2 - line.size.w div 2, 0)
      for atom in line.atoms:
        atom.offset.x += x
        ictx.size.w = max(atom.offset.x + atom.size.w, ictx.size.w)

# Align atoms (inline boxes, text, etc.) vertically (i.e. along the inline
# axis) inside the line.
proc verticalAlignLine(ictx: var InlineContext) =
  # Start with line-height as the baseline and line height.
  let lineheight = ictx.currentLine.lineheight
  ictx.currentLine.size.h = lineheight
  var baseline = lineheight

  # Calculate the line's baseline based on atoms' baseline.
  # Also, collect the maximum vertical margins of inline blocks.
  var marginTop: LayoutUnit = 0
  var bottomEdge = baseline
  for i, atom in ictx.currentLine.atoms:
    let iastate = ictx.currentLine.atomstates[i]
    case iastate.vertalign.keyword
    of VerticalAlignBaseline:
      let len = iastate.vertalign.length.px(ictx.lctx, lineheight)
      baseline = max(baseline, iastate.baseline + len)
    of VerticalAlignTop, VerticalAlignBottom:
      baseline = max(baseline, atom.size.h)
    of VerticalAlignMiddle:
      baseline = max(baseline, atom.size.h div 2)
    else:
      baseline = max(baseline, iastate.baseline)

  let ch = ictx.cellheight
  baseline = baseline.round(ch)

  # Resize the line's height based on atoms' height and baseline.
  # The line height should be at least as high as the highest baseline used by
  # an atom plus that atom's height.
  for i, atom in ictx.currentLine.atoms:
    let iastate = ictx.currentLine.atomstates[i]
    # In all cases, the line's height must at least equal the atom's height.
    # (Where the atom is actually placed is irrelevant here.)
    ictx.currentLine.size.h = max(ictx.currentLine.size.h, atom.size.h)
    case iastate.vertalign.keyword
    of VerticalAlignBaseline:
      # Line height must be at least as high as
      # (line baseline) - (atom baseline) + (atom height) + (extra height).
      let len = iastate.vertalign.length.px(ictx.lctx, lineheight)
      ictx.currentLine.size.h = max(baseline - iastate.baseline +
        atom.size.h + len, ictx.currentLine.size.h)
    of VerticalAlignMiddle:
      # Line height must be at least
      # (line baseline) + (atom height / 2).
      ictx.currentLine.size.h = max(baseline + atom.size.h div 2,
        ictx.currentLine.size.h)
    of VerticalAlignTop, VerticalAlignBottom:
      # Line height must be at least atom height (already ensured above.)
      discard
    else:
      # See baseline (with len = 0).
      ictx.currentLine.size.h = max(baseline - iastate.baseline +
        atom.size.h, ictx.currentLine.size.h)

  # Now we can calculate the actual position of atoms inside the line.
  for i, atom in ictx.currentLine.atoms:
    let iastate = ictx.currentLine.atomstates[i]
    case iastate.vertalign.keyword
    of VerticalAlignBaseline:
      # Atom is placed at (line baseline) - (atom baseline) - len
      let len = iastate.vertalign.length.px(ictx.lctx, lineheight)
      atom.offset.y = baseline - iastate.baseline - len
    of VerticalAlignMiddle:
      # Atom is placed at (line baseline) - ((atom height) / 2)
      atom.offset.y = baseline - atom.size.h div 2
    of VerticalAlignTop:
      # Atom is placed at the top of the line.
      atom.offset.y = 0
    of VerticalAlignBottom:
      # Atom is placed at the bottom of the line.
      atom.offset.y = ictx.currentLine.size.h - atom.size.h
    else:
      # See baseline (with len = 0).
      atom.offset.y = baseline - iastate.baseline
    # Find the best top margin and bottom edge of all atoms.
    # In fact, we are looking for the lowest top edge and the highest bottom
    # edge of the line, so we have to do this after we know where the atoms
    # will be placed.
    marginTop = max(iastate.marginTop - atom.offset.y, marginTop)
    bottomEdge = max(atom.offset.y + atom.size.h + iastate.marginBottom,
      bottomEdge)

  # Finally, offset all atoms' y position by the largest top margin and the
  # line box's top padding.
  let paddingTop = ictx.currentLine.paddingTop
  let offsety = ictx.currentLine.offsety
  for atom in ictx.currentLine.atoms:
    atom.offset.y = (atom.offset.y + marginTop + paddingTop + offsety).round(ch)
    ictx.currentLine.minHeight = max(ictx.currentLine.minHeight,
      atom.offset.y - offsety + atom.size.h)

  ictx.currentLine.baseline = baseline
  #TODO this does not really work with rounding :/
  ictx.currentLine.baseline += ictx.currentLine.paddingTop
  # Ensure that the line is exactly as high as its highest atom demands,
  # rounded up to the next line.
  # (This is almost the same as completely ignoring line height. However, there
  # is a difference because line height is still taken into account when
  # positioning the atoms.)
  ictx.currentLine.size.h = ictx.currentLine.minHeight.ceilTo(ch)
  # Now, if we got a height that is lower than cell height *and* line height,
  # then set it back to the cell height. (This is to avoid the situation where
  # we would swallow hard line breaks with <br>.)
  if lineheight >= ch and ictx.currentLine.size.h < ch:
    ictx.currentLine.size.h = ch
  # Set the line height to size.h.
  ictx.currentLine.line.height = ictx.currentLine.size.h

proc putAtom(state: var LineBoxState; atom: InlineAtom;
    iastate: InlineAtomState; fragment: InlineFragment) =
  state.atomstates.add(iastate)
  state.atoms.add(atom)
  fragment.atoms.add(atom)

proc addSpacing(ictx: var InlineContext; width, height: LayoutUnit;
    state: InlineState; hang = false) =
  let spacing = InlineAtom(
    t: iatSpacing,
    size: size(w = width, h = height),
    offset: offset(x = ictx.currentLine.size.w, y = 0)
  )
  let iastate = InlineAtomState(baseline: height)
  if not hang:
    # In some cases, whitespace may "hang" at the end of the line. This means
    # it is written, but is not actually counted in the box's width.
    ictx.currentLine.size.w += width
  ictx.currentLine.putAtom(spacing, iastate, ictx.whitespaceFragment)

proc flushWhitespace(ictx: var InlineContext; state: InlineState;
    hang = false) =
  let shift = ictx.computeShift(state)
  ictx.currentLine.charwidth += ictx.whitespacenum
  ictx.whitespacenum = 0
  if shift > 0:
    ictx.addSpacing(shift, ictx.cellheight, state, hang)

# Prepare the next line's initial width and available width.
# (If space on the left is excluded by floats, set the initial width to
# the end of that space. If space on the right is excluded, set the available
# width to that space.)
proc initLine(ictx: var InlineContext) =
  ictx.currentLine.availableWidth = ictx.space.w.u
  let bctx = ictx.bctx
  #TODO what if maxContent/minContent?
  if bctx.exclusions.len != 0:
    let bfcOffset = ictx.bfcOffset
    let y = ictx.currentLine.offsety + bfcOffset.y
    var left = bfcOffset.x
    var right = bfcOffset.x + ictx.currentLine.availableWidth
    for ex in bctx.exclusions:
      if ex.offset.y <= y and y < ex.offset.y + ex.size.h:
        ictx.currentLine.hasExclusion = true
        if ex.t == FloatLeft:
          left = ex.offset.x + ex.size.w
        else:
          right = ex.offset.x
    ictx.currentLine.line.size.w = left - bfcOffset.x
    ictx.currentLine.availableWidth = right - bfcOffset.x

proc finishLine(ictx: var InlineContext; state: var InlineState; wrap: bool;
    force = false) =
  if ictx.currentLine.atoms.len != 0 or force:
    let whitespace = state.computed{"white-space"}
    if whitespace == WhitespacePre:
      ictx.flushWhitespace(state)
    elif whitespace == WhitespacePreWrap:
      ictx.flushWhitespace(state, hang = true)
    else:
      ictx.whitespacenum = 0
    ictx.verticalAlignLine()
    # add line to ictx
    let y = ictx.currentLine.offsety
    # * set first baseline if this is the first line box
    # * always set last baseline (so the baseline of the last line box remains)
    if ictx.lines.len == 0:
      ictx.root.firstBaseline = y + ictx.currentLine.baseline
    ictx.root.baseline = y + ictx.currentLine.baseline
    ictx.size.h += ictx.currentLine.size.h
    let lineWidth = if wrap:
      ictx.currentLine.availableWidth
    else:
      ictx.currentLine.size.w
    if state.firstLine:
      #TODO padding top
      state.fragment.startOffset = offset(
        x = state.startOffsetTop.x,
        y = y + ictx.currentLine.size.h
      )
      state.firstLine = false
    ictx.size.w = max(ictx.size.w, lineWidth)
    ictx.lines.add(ictx.currentLine.line)
    ictx.currentLine = LineBoxState(
      line: LineBox(offsety: y + ictx.currentLine.size.h)
    )
    ictx.initLine()

proc addBackgroundAreas(ictx: var InlineContext; rootFragment: InlineFragment) =
  var traverseStack: seq[InlineFragment] = @[rootFragment]
  var currentStack: seq[InlineFragment] = @[]
  template top: InlineFragment = currentStack[^1]
  var atomIdx = 0
  var lineSkipped = false
  for line in ictx.lines:
    if line.atoms.len == 0:
      # no atoms here; set lineSkipped to true so that we don't accidentally
      # extend background areas over this
      lineSkipped = true
      continue
    var prevEnd: LayoutUnit = 0
    for atom in line.atoms:
      if currentStack.len == 0 or atomIdx >= top.atoms.len:
        atomIdx = 0
        while true:
          let thisNode = traverseStack.pop()
          if thisNode == nil: # sentinel found
            let oldTop = currentStack.pop()
            # finish oldTop area
            if oldTop.areas[^1].offset.y == line.offsety:
              # if offset.y is this offsety, then it means that we added it on
              # this line, so we just have to set its width
              if prevEnd > 0:
                oldTop.areas[^1].size.w = prevEnd - oldTop.areas[^1].offset.x
              else:
                # fragment got dropped without prevEnd moving anywhere; delete
                # area
                oldTop.areas.setLen(oldTop.areas.high)
            elif prevEnd > 0:
              # offset.y is presumably from a previous line
              # (if prevEnd is 0, then the area doesn't extend to this line,
              # so we do not have to do anything.)
              let x = line.atoms[0].offset.x
              let w = prevEnd - x
              if oldTop.areas[^1].offset.x == x and
                  oldTop.areas[^1].size.w == w:
                # same vertical dimensions; just extend.
                oldTop.areas[^1].size.h = line.offsety + line.height -
                  oldTop.areas[^1].offset.y
              else:
                # vertical dimensions differ; add new area.
                oldTop.areas.add(Area(
                  offset: offset(x = x, y = line.offsety),
                  size: size(w = w, h = line.height)
                ))
            continue
          traverseStack.add(nil) # sentinel
          for i in countdown(thisNode.children.high, 0):
            traverseStack.add(thisNode.children[i])
          thisNode.areas.add(Area(
            offset: offset(x = atom.offset.x, y = line.offsety),
            size: size(w = atom.size.w, h = line.height)
          ))
          currentStack.add(thisNode)
          if thisNode.atoms.len > 0:
            break
      prevEnd = atom.offset.x + atom.size.w
      assert top.atoms[atomIdx] == atom
      inc atomIdx
    # extend current areas
    for node in currentStack:
      if node.areas[^1].offset.y == line.offsety:
        # added in this iteration. no need to extend vertically, but make sure
        # that it reaches prevEnd.
        node.areas[^1].size.w = prevEnd - node.areas[^1].offset.x
        continue
      let x1 = node.areas[^1].offset.x
      let x2 = node.areas[^1].offset.x + node.areas[^1].size.w
      if x1 == line.atoms[0].offset.x and x2 == prevEnd and not lineSkipped:
        # horizontal dimensions are the same as for the last area. just move its
        # vertical end to the current line's end.
        node.areas[^1].size.h = line.offsety + line.height -
          node.areas[^1].offset.y
      else:
        # horizontal dimensions differ; add a new area
        node.areas.add(Area(
          offset: offset(x = line.atoms[0].offset.x, y = line.offsety),
          size: size(w = prevEnd - line.atoms[0].offset.x, h = line.height)
        ))
    lineSkipped = false

func minwidth(atom: InlineAtom): LayoutUnit =
  if atom.t == iatInlineBlock:
    return atom.innerbox.xminwidth
  return atom.size.w

func shouldWrap(ictx: InlineContext; w: LayoutUnit;
    pcomputed: CSSComputedValues): bool =
  if pcomputed != nil and pcomputed.nowrap:
    return false
  if ictx.space.w.t == scMaxContent:
    return false # no wrap with max-content
  if ictx.space.w.t == scMinContent:
    return true # always wrap with min-content
  return ictx.currentLine.size.w + w > ictx.currentLine.availableWidth

func shouldWrap2(ictx: InlineContext; w: LayoutUnit): bool =
  if not ictx.currentLine.hasExclusion:
    return false
  return ictx.currentLine.size.w + w > ictx.currentLine.availableWidth

# Start a new line, even if the previous one is empty
proc flushLine(ictx: var InlineContext; state: var InlineState) =
  ictx.applyLineHeight(ictx.currentLine, state.computed)
  ictx.finishLine(state, wrap = false, force = true)

# Add an inline atom atom, with state iastate.
# Returns true on newline.
proc addAtom(ictx: var InlineContext; state: var InlineState;
    iastate: InlineAtomState; atom: InlineAtom): bool =
  result = false
  var shift = ictx.computeShift(state)
  ictx.currentLine.charwidth += ictx.whitespacenum
  ictx.whitespacenum = 0
  # Line wrapping
  if ictx.shouldWrap(atom.size.w + shift, state.computed):
    ictx.finishLine(state, wrap = true, force = false)
    result = true
    # Recompute on newline
    shift = ictx.computeShift(state)
    # For floats: flush lines until we can place the atom.
    #TODO this is inefficient
    while ictx.shouldWrap2(atom.size.w + shift):
      ictx.applyLineHeight(ictx.currentLine, state.computed)
      ictx.currentLine.lineheight = max(ictx.currentLine.lineheight,
        ictx.cellheight)
      ictx.finishLine(state, wrap = false, force = true)
      # Recompute on newline
      shift = ictx.computeShift(state)
  if atom.size.w > 0 and atom.size.h > 0:
    if shift > 0:
      ictx.addSpacing(shift, ictx.cellheight, state)
    ictx.minwidth = max(ictx.minwidth, atom.minwidth)
    ictx.applyLineHeight(ictx.currentLine, state.computed)
    if atom.t != iatWord:
      ictx.currentLine.charwidth = 0
    ictx.currentLine.putAtom(atom, iastate, state.fragment)
    atom.offset.x += ictx.currentLine.size.w
    ictx.currentLine.size.w += atom.size.w

proc addWord(ictx: var InlineContext; state: var InlineState): bool =
  result = false
  if ictx.word.str != "":
    ictx.word.str.mnormalize() #TODO this may break on EOL.
    result = ictx.addAtom(state, ictx.wordstate, ictx.word)
    ictx.newWord(state)

proc addWordEOL(ictx: var InlineContext; state: var InlineState): bool =
  result = false
  if ictx.word.str != "":
    if ictx.wrappos != -1:
      let leftstr = ictx.word.str.substr(ictx.wrappos)
      ictx.word.str.setLen(ictx.wrappos)
      if ictx.hasshy:
        const shy = $Rune(0xAD) # soft hyphen
        ictx.word.str &= shy
        ictx.hasshy = false
      result = ictx.addWord(state)
      ictx.word.str = leftstr
      ictx.word.size.w = leftstr.width() * ictx.cellwidth
    else:
      result = ictx.addWord(state)

proc checkWrap(ictx: var InlineContext; state: var InlineState; r: Rune) =
  if state.computed.nowrap:
    return
  let shift = ictx.computeShift(state)
  let rw = r.width()
  state.prevrw = rw
  if ictx.word.str.len == 0:
    state.firstrw = rw
  if rw >= 2:
    # remove wrap opportunity, so we wrap properly on the last CJK char (instead
    # of any dash inside CJK sentences)
    ictx.wrappos = -1
  case state.computed{"word-break"}
  of WordBreakNormal:
    if rw == 2 or ictx.wrappos != -1: # break on cjk and wrap opportunities
      let plusWidth = ictx.word.size.w + shift + rw * ictx.cellwidth
      if ictx.shouldWrap(plusWidth, nil):
        if not ictx.addWordEOL(state): # no line wrapping occured in addAtom
          ictx.finishLine(state, wrap = true)
          ictx.whitespacenum = 0
  of WordBreakBreakAll:
    let plusWidth = ictx.word.size.w + shift + rw * ictx.cellwidth
    if ictx.shouldWrap(plusWidth, nil):
      if not ictx.addWordEOL(state): # no line wrapping occured in addAtom
        ictx.finishLine(state, wrap = true)
        ictx.whitespacenum = 0
  of WordBreakKeepAll:
    let plusWidth = ictx.word.size.w + shift + rw * ictx.cellwidth
    if ictx.shouldWrap(plusWidth, nil):
      ictx.finishLine(state, wrap = true)
      ictx.whitespacenum = 0

proc processWhitespace(ictx: var InlineContext; state: var InlineState;
    c: char) =
  discard ictx.addWord(state)
  case state.computed{"white-space"}
  of WhitespaceNormal, WhitespaceNowrap:
    if ictx.whitespacenum < 1:
      ictx.whitespacenum = 1
      ictx.whitespaceFragment = state.fragment
      ictx.whitespaceIsLF = c == '\n'
    if c != '\n':
      ictx.whitespaceIsLF = false
  of WhitespacePreLine:
    if c == '\n':
      ictx.flushLine(state)
    elif ictx.whitespacenum < 1:
      ictx.whitespaceIsLF = false
      ictx.whitespacenum = 1
      ictx.whitespaceFragment = state.fragment
  of WhitespacePre, WhitespacePreWrap:
    #TODO whitespace type should be preserved here. (it isn't, because
    # it would break tabs in the current buffer model.)
    ictx.whitespaceIsLF = false
    if c == '\n':
      ictx.flushLine(state)
    elif c == '\t':
      let realWidth = ictx.currentLine.charwidth + ictx.whitespacenum
      let targetTabStops = realWidth div 8 + 1
      let targetWidth = targetTabStops * 8
      ictx.whitespacenum += targetWidth - realWidth
      ictx.whitespaceFragment = state.fragment
    else:
      inc ictx.whitespacenum
      ictx.whitespaceFragment = state.fragment
  # set the "last word's last rune width" to the previous rune width
  state.lastrw = state.prevrw

func initInlineContext(bctx: var BlockContext; space: AvailableSpace;
    bfcOffset: Offset; root: RootInlineFragment): InlineContext =
  var ictx = InlineContext(
    currentLine: LineBoxState(
      line: LineBox()
    ),
    bctx: addr bctx,
    lctx: bctx.lctx,
    bfcOffset: bfcOffset,
    space: space,
    root: root
  )
  ictx.initLine()
  return ictx

proc layoutTextLoop(ictx: var InlineContext; state: var InlineState;
    str: string) =
  var i = 0
  while i < str.len:
    let c = str[i]
    if c in Ascii:
      if c in AsciiWhitespace:
        ictx.processWhitespace(state, c)
      else:
        let r = Rune(c)
        ictx.checkWrap(state, r)
        ictx.word.str &= c
        let w = r.width()
        ictx.word.size.w += w * ictx.cellwidth
        ictx.currentLine.charwidth += w
        if c == '-': # ascii dash
          ictx.wrappos = ictx.word.str.len
          ictx.hasshy = false
      inc i
    else:
      var r: Rune
      fastRuneAt(str, i, r)
      ictx.checkWrap(state, r)
      if r == Rune(0xAD): # soft hyphen
        ictx.wrappos = ictx.word.str.len
        ictx.hasshy = true
      else:
        ictx.word.str &= r
        let w = r.width()
        ictx.word.size.w += w * ictx.cellwidth
        ictx.currentLine.charwidth += w
  discard ictx.addWord(state)
  let shift = ictx.computeShift(state)
  ictx.currentLine.widthAfterWhitespace = ictx.currentLine.size.w + shift

iterator transform(text: seq[string]; v: CSSTextTransform): string {.inline.} =
  if v == TextTransformNone:
    for str in text:
      yield str
  else:
    for str in text:
      let str = case v
      of TextTransformCapitalize: str.capitalizeLU()
      of TextTransformUppercase: str.toUpperLU()
      of TextTransformLowercase: str.toLowerLU()
      of TextTransformFullWidth: str.fullwidth()
      of TextTransformFullSizeKana: str.fullsize()
      of TextTransformChaHalfWidth: str.halfwidth()
      else: ""
      yield str

proc layoutText(ictx: var InlineContext; state: var InlineState;
    text: seq[string]) =
  for str in text.transform(state.computed{"text-transform"}):
    ictx.flushWhitespace(state)
    ictx.newWord(state)
    ictx.layoutTextLoop(state, str)

func spx(l: CSSLength; lctx: LayoutState; p: SizeConstraint;
    computed: CSSComputedValues; padding: LayoutUnit): LayoutUnit =
  let u = l.px(lctx, p)
  if computed{"box-sizing"} == BoxSizingBorderBox:
    return max(u - padding, 0)
  return max(u, 0)

func spx(l: CSSLength; lctx: LayoutState; p: Option[LayoutUnit];
    computed: CSSComputedValues; padding: LayoutUnit): Option[LayoutUnit] =
  let u = l.px(lctx, p)
  if u.isSome:
    let u = u.get
    if computed{"box-sizing"} == BoxSizingBorderBox:
      return some(max(u - padding, 0))
    return some(max(u, 0))
  return u

proc resolveContentWidth(sizes: var ResolvedSizes; widthpx: LayoutUnit;
    containingWidth: SizeConstraint; computed: CSSComputedValues;
    isauto = false) =
  if not sizes.space.w.isDefinite():
    # width is indefinite, so no conflicts can be resolved here.
    return
  let total = widthpx + sizes.margin.left + sizes.margin.right +
    sizes.padding.left + sizes.padding.right
  let underflow = containingWidth.u - total
  if isauto or sizes.space.w.t == scFitContent:
    if underflow >= 0:
      sizes.space.w = SizeConstraint(t: sizes.space.w.t, u: underflow)
    else:
      sizes.margin.right += underflow
  elif underflow > 0:
    if not computed{"margin-left"}.auto and not computed{"margin-right"}.auto:
      sizes.margin.right += underflow
    elif not computed{"margin-left"}.auto and computed{"margin-right"}.auto:
      sizes.margin.right = underflow
    elif computed{"margin-left"}.auto and not computed{"margin-right"}.auto:
      sizes.margin.left = underflow
    else:
      sizes.margin.left = underflow div 2
      sizes.margin.right = underflow div 2

proc resolveMargins(availableWidth: SizeConstraint; lctx: LayoutState;
    computed: CSSComputedValues): RelativeRect =
  # Note: we use availableWidth for percentage resolution intentionally.
  return RelativeRect(
    top: computed{"margin-top"}.px(lctx, availableWidth),
    bottom: computed{"margin-bottom"}.px(lctx, availableWidth),
    left: computed{"margin-left"}.px(lctx, availableWidth),
    right: computed{"margin-right"}.px(lctx, availableWidth)
  )

proc resolvePadding(availableWidth: SizeConstraint; lctx: LayoutState;
    computed: CSSComputedValues): RelativeRect =
  # Note: we use availableWidth for percentage resolution intentionally.
  return RelativeRect(
    top: computed{"padding-top"}.px(lctx, availableWidth),
    bottom: computed{"padding-bottom"}.px(lctx, availableWidth),
    left: computed{"padding-left"}.px(lctx, availableWidth),
    right: computed{"padding-right"}.px(lctx, availableWidth)
  )

func resolvePositioned(space: AvailableSpace; lctx: LayoutState;
    computed: CSSComputedValues): RelativeRect =
  # As per standard, vertical percentages refer to the *height*, not the width
  # (unlike with margin/padding)
  return RelativeRect(
    top: computed{"top"}.px(lctx, space.h),
    bottom: computed{"bottom"}.px(lctx, space.h),
    left: computed{"left"}.px(lctx, space.w),
    right: computed{"right"}.px(lctx, space.w)
  )

proc resolveBlockWidth(sizes: var ResolvedSizes;
    containingWidth: SizeConstraint; computed: CSSComputedValues;
    lctx: LayoutState) =
  let width = computed{"width"}
  let padding = sizes.padding.left + sizes.padding.right
  var widthpx: LayoutUnit = 0
  if width.canpx(containingWidth):
    widthpx = width.spx(lctx, containingWidth, computed, padding)
    sizes.space.w = stretch(widthpx)
  sizes.resolveContentWidth(widthpx, containingWidth, computed, width.auto)
  if not computed{"max-width"}.auto:
    let maxWidth = computed{"max-width"}.spx(lctx, containingWidth, computed,
      padding)
    sizes.maxWidth = maxWidth
    if sizes.space.w.t in {scStretch, scFitContent} and
        maxWidth < sizes.space.w.u or sizes.space.w.t == scMaxContent:
      sizes.space.w = stretch(maxWidth) #TODO is stretch ok here?
      if sizes.space.w.t == scStretch:
        # available width would stretch over max-width
        sizes.space.w = stretch(maxWidth)
      else: # scFitContent
        # available width could be higher than max-width (but not necessarily)
        sizes.space.w = fitContent(maxWidth)
      sizes.resolveContentWidth(maxWidth, containingWidth, computed)
  if not computed{"min-width"}.auto:
    let minWidth = computed{"min-width"}.spx(lctx, containingWidth, computed,
      padding)
    sizes.minWidth = minWidth
    if sizes.space.w.t in {scStretch, scFitContent} and
        minWidth > sizes.space.w.u or sizes.space.w.t == scMinContent:
      # two cases:
      # * available width is stretched under min-width. in this case,
      #   stretch to min-width instead.
      # * available width is fit under min-width. in this case, stretch to
      #   min-width as well (as we must satisfy min-width >= width).
      sizes.space.w = stretch(minWidth)
      sizes.resolveContentWidth(minWidth, containingWidth, computed)

proc resolveBlockHeight(sizes: var ResolvedSizes;
    containingHeight: SizeConstraint; percHeight: Option[LayoutUnit];
    computed: CSSComputedValues; lctx: LayoutState) =
  let height = computed{"height"}
  let padding = sizes.padding.top + sizes.padding.bottom
  var heightpx: LayoutUnit = 0
  if height.canpx(percHeight):
    heightpx = height.spx(lctx, percHeight, computed, padding).get
    sizes.space.h = stretch(heightpx)
  if not computed{"max-height"}.auto:
    let maxHeight = computed{"max-height"}.spx(lctx, percHeight, computed,
      padding)
    sizes.maxHeight = maxHeight.get(high(LayoutUnit))
    if maxHeight.isSome:
      let maxHeight = maxHeight.get
      if sizes.space.h.t in {scStretch, scFitContent} and
          maxHeight < sizes.space.h.u or sizes.space.h.t == scMaxContent:
        # same reasoning as for width.
        if sizes.space.h.t == scStretch:
          sizes.space.h = stretch(maxHeight)
        else: # scFitContent
          sizes.space.h = fitContent(maxHeight)
  if not computed{"min-height"}.auto:
    let minHeight = computed{"min-height"}.spx(lctx, percHeight, computed,
      padding)
    sizes.minHeight = minHeight.get(0)
    if minHeight.isSome:
      let minHeight = minHeight.get
      if sizes.space.h.t in {scStretch, scFitContent} and
          minHeight > sizes.space.h.u or sizes.space.h.t == scMinContent:
        # same reasoning as for width.
        sizes.space.h = stretch(minHeight)

proc resolveAbsoluteSize(sizes: var ResolvedSizes; space: AvailableSpace;
    dim: DimensionType; cvalSize, cvalLeft, cvalRight: CSSLength;
    computed: CSSComputedValues; lctx: LayoutState) =
  # Note: cvalLeft, cvalRight are top/bottom when called with vertical dim
  if cvalSize.auto:
    if space[dim].isDefinite:
      let u = max(space[dim].u - sizes.positioned.dimSum(dim) -
        sizes.margin.dimSum(dim) - sizes.padding.dimSum(dim), 0)
      if not cvalLeft.auto and not cvalRight.auto:
        # width is auto and left & right are not auto.
        # Solve for width.
        sizes.space[dim] = stretch(u)
      else:
        # Return shrink to fit and solve for left/right.
        sizes.space[dim] = fitContent(u)
    else:
      sizes.space[dim] = space[dim]
  else:
    let padding = sizes.padding.dimSum(dim)
    let sizepx = cvalSize.spx(lctx, space[dim], computed, padding)
    # We could solve for left/right here, as available width is known.
    # Nevertheless, it is only needed for positioning, so we do not solve
    # them yet.
    sizes.space[dim] = stretch(sizepx)

proc resolveBlockSizes(lctx: LayoutState; space: AvailableSpace;
    percHeight: Option[LayoutUnit]; computed: CSSComputedValues):
    ResolvedSizes =
  var sizes = ResolvedSizes(
    margin: resolveMargins(space.w, lctx, computed),
    padding: resolvePadding(space.w, lctx, computed),
    # Take defined sizes if our width/height resolves to auto.
    # For block boxes, this is:
    # (width: stretch(parentWidth), height: max-content)
    space: space,
    minMaxSizes: [dtHorizontal: DefaultSpan, dtVertical: DefaultSpan]
  )
  if computed{"position"} == PositionRelative:
    # only compute this when needed
    sizes.positioned = resolvePositioned(space, lctx, computed)
  # Finally, calculate available width and height.
  sizes.resolveBlockWidth(space.w, computed, lctx)
  sizes.resolveBlockHeight(space.h, percHeight, computed, lctx)
  return sizes

# Calculate and resolve available width & height for absolutely positioned
# boxes.
proc resolveAbsoluteSizes(lctx: LayoutState; computed: CSSComputedValues):
    ResolvedSizes =
  let space = lctx.positioned[^1]
  var sizes = ResolvedSizes(
    margin: resolveMargins(space.w, lctx, computed),
    padding: resolvePadding(space.w, lctx, computed),
    positioned: resolvePositioned(space, lctx, computed),
    minMaxSizes: [dtHorizontal: DefaultSpan, dtVertical: DefaultSpan]
  )
  sizes.resolveAbsoluteSize(space, dtHorizontal, computed{"width"},
    computed{"left"}, computed{"right"}, computed, lctx)
  #TODO this might be incorrect because of percHeight?
  sizes.resolveAbsoluteSize(space, dtVertical, computed{"height"},
    computed{"top"}, computed{"bottom"}, computed, lctx)
  return sizes

# Calculate and resolve available width & height for floating boxes.
proc resolveFloatSizes(lctx: LayoutState; space: AvailableSpace;
    percHeight: Option[LayoutUnit]; computed: CSSComputedValues):
    ResolvedSizes =
  var space = availableSpace(
    w = fitContent(space.w),
    h = space.h
  )
  let padding = resolvePadding(space.w, lctx, computed)
  let inlinePadding = padding.left + padding.right
  let blockPadding = padding.top + padding.bottom
  let minWidth: LayoutUnit = if not computed{"min-width"}.auto:
    computed{"min-width"}.spx(lctx, space.w, computed, inlinePadding)
  else:
    0
  let maxWidth = if not computed{"max-width"}.auto:
    computed{"max-width"}.spx(lctx, space.w, computed, inlinePadding)
  else:
    high(LayoutUnit)
  let width = computed{"width"}
  if width.canpx(space.w):
    let widthpx = width.spx(lctx, space.w, computed, inlinePadding)
    space.w = stretch(clamp(widthpx, minWidth, maxWidth))
  elif space.w.isDefinite():
    space.w = fitContent(clamp(space.w.u, minWidth, maxWidth))
  let minHeight: LayoutUnit = if not computed{"min-height"}.auto:
    computed{"min-height"}.spx(lctx, percHeight, computed, blockPadding).get(0)
  else:
    0
  let maxHeight = if not computed{"max-height"}.auto:
    computed{"max-height"}.spx(lctx, percHeight, computed, blockPadding)
      .get(high(LayoutUnit))
  else:
    high(LayoutUnit)
  let height = computed{"height"}
  if height.canpx(space.h):
    let heightpx = height.px(lctx, space.h)
    space.h = stretch(clamp(heightpx, minHeight, maxHeight))
  elif space.h.isDefinite():
    space.h = fitContent(clamp(space.h.u, minHeight, maxHeight))
  return ResolvedSizes(
    margin: resolveMargins(space.w, lctx, computed),
    padding: padding,
    space: space,
    minMaxSizes: [
      dtHorizontal: MinMaxSpan(min: minWidth, max: maxWidth),
      dtVertical: MinMaxSpan(min: minHeight, max: maxHeight)
    ]
  )

# Calculate and resolve available width & height for box children.
# containingWidth: width of the containing box
# containingHeight: ditto; but with height.
# Note that this is not the final content size, just the amount of space
# available for content.
# The percentage width/height is generally
# availableSize.isDefinite() ? availableSize.u : 0, but for some reason it
# differs for the root height (TODO: and all heights in quirks mode) in that
# it uses the lctx height. Therefore we pass percHeight as a separate
# parameter. (TODO surely there is a better solution to this?)
proc resolveSizes(lctx: LayoutState; space: AvailableSpace;
    percHeight: Option[LayoutUnit]; computed: CSSComputedValues):
    ResolvedSizes =
  if computed{"position"} == PositionAbsolute:
    return lctx.resolveAbsoluteSizes(computed)
  elif computed{"float"} != FloatNone:
    return lctx.resolveFloatSizes(space, percHeight, computed)
  else:
    return lctx.resolveBlockSizes(space, percHeight, computed)

func toPercSize(sc: SizeConstraint): Option[LayoutUnit] =
  if sc.isDefinite():
    return some(sc.u)
  return none(LayoutUnit)

proc append(a: var Strut; b: LayoutUnit) =
  if b < 0:
    a.neg = min(b, a.neg)
  else:
    a.pos = max(b, a.pos)

func sum(a: Strut): LayoutUnit =
  return a.pos + a.neg

proc layoutRootInline(bctx: var BlockContext; inlines: seq[BoxBuilder];
  space: AvailableSpace; computed: CSSComputedValues;
  offset, bfcOffset: Offset): RootInlineFragment
proc layoutBlock(bctx: var BlockContext; box: BlockBox;
  builder: BlockBoxBuilder; sizes: ResolvedSizes)
proc layoutTable(bctx: BlockContext; table: BlockBox; builder: TableBoxBuilder;
  sizes: ResolvedSizes)
proc layoutFlex(bctx: var BlockContext; box: BlockBox; builder: BlockBoxBuilder;
  sizes: ResolvedSizes)
proc layoutInline(ictx: var InlineContext; box: InlineBoxBuilder):
  InlineFragment

# Note: padding must still be applied after this.
proc applySize(box: BlockBox; sizes: ResolvedSizes;
    maxChildSize: LayoutUnit; space: AvailableSpace; dim: DimensionType) =
  # Make the box as small/large as the content's width or specified width.
  box.size[dim] = maxChildSize.applySizeConstraint(space[dim])
  # Then, clamp it to minWidth and maxWidth (if applicable).
  let minMax = sizes.minMaxSizes[dim]
  box.size[dim] = clamp(box.size[dim], minMax.min, minMax.max)

proc applyWidth(box: BlockBox; sizes: ResolvedSizes;
    maxChildWidth: LayoutUnit; space: AvailableSpace) =
  box.applySize(sizes, maxChildWidth, space, dtHorizontal)

proc applyWidth(box: BlockBox; sizes: ResolvedSizes;
    maxChildWidth: LayoutUnit) =
  box.applyWidth(sizes, maxChildWidth, sizes.space)

proc applyHeight(box: BlockBox; sizes: ResolvedSizes;
    maxChildHeight: LayoutUnit) =
  box.applySize(sizes, maxChildHeight, sizes.space, dtVertical)

proc applyPadding(box: BlockBox; padding: RelativeRect) =
  box.size.w += padding.left
  box.size.w += padding.right
  box.size.h += padding.top
  box.size.h += padding.bottom

func bfcOffset(bctx: BlockContext): Offset =
  if bctx.parentBps != nil:
    return bctx.parentBps.offset
  return offset(x = 0, y = 0)

proc layoutInline(bctx: var BlockContext; box: BlockBox;
    children: seq[BoxBuilder], sizes: ResolvedSizes) =
  var bfcOffset = bctx.bfcOffset
  let offset = offset(x = sizes.padding.left, y = sizes.padding.top)
  bfcOffset.x += box.offset.x + offset.x
  bfcOffset.y += box.offset.y + offset.y
  box.inline = bctx.layoutRootInline(children, sizes.space, box.computed,
    offset, bfcOffset)
  box.xminwidth = max(box.xminwidth, box.inline.xminwidth)
  box.size.w = box.inline.size.w + sizes.padding.left + sizes.padding.right
  box.applyWidth(sizes, box.inline.size.w)
  box.applyHeight(sizes, box.inline.size.h)
  box.applyPadding(sizes.padding)
  box.baseline = offset.y + box.inline.baseline
  box.firstBaseline = offset.y + box.inline.firstBaseline

const DisplayBlockLike = {DisplayBlock, DisplayListItem, DisplayInlineBlock}

# Return true if no more margin collapsing can occur for the current strut.
func canFlushMargins(builder: BlockBoxBuilder; sizes: ResolvedSizes): bool =
  if builder.computed{"position"} == PositionAbsolute:
    return false
  return sizes.padding.top != 0 or sizes.padding.bottom != 0 or
    builder.inlinelayout or builder.computed{"display"} notin DisplayBlockLike

proc flushMargins(bctx: var BlockContext; box: BlockBox) =
  # Apply uncommitted margins.
  let margin = bctx.marginTodo.sum()
  if bctx.marginTarget == nil:
    box.offset.y += margin
  else:
    if bctx.marginTarget.box != nil:
      bctx.marginTarget.box.offset.y += margin
    var p = bctx.marginTarget
    while true:
      p.offset.y += margin
      p.resolved = true
      p = p.next
      if p == nil: break
    bctx.marginTarget = nil
  bctx.marginTodo = Strut()

proc clearFloats(offset: var Offset; bctx: var BlockContext; clear: CSSClear) =
  var y = bctx.bfcOffset.y + offset.y
  case clear
  of ClearLeft, ClearInlineStart:
    for ex in bctx.exclusions:
      if ex.t == FloatLeft:
        y = max(ex.offset.y + ex.size.h, y)
  of ClearRight, ClearInlineEnd:
    for ex in bctx.exclusions:
      if ex.t == FloatRight:
        y = max(ex.offset.y + ex.size.h, y)
  of ClearBoth:
    for ex in bctx.exclusions:
      y = max(ex.offset.y + ex.size.h, y)
  of ClearNone: assert false
  bctx.clearOffset = y
  offset.y = y - bctx.bfcOffset.y

type
  BlockState = object
    offset: Offset
    maxChildWidth: LayoutUnit
    totalFloatWidth: LayoutUnit # used for re-layouts
    nested: seq[BlockBox]
    space: AvailableSpace
    xminwidth: LayoutUnit
    prevParentBps: BlockPositionState
    needsReLayout: bool
    # State kept for when a re-layout is necessary:
    oldMarginTodo: Strut
    oldExclusionsLen: int
    initialMarginTarget: BlockPositionState
    initialTargetOffset: Offset
    initialParentOffset: Offset

func findNextFloatOffset(bctx: BlockContext; offset: Offset; size: Size;
    space: AvailableSpace; float: CSSFloat; outw: var LayoutUnit): Offset =
  # Algorithm originally from QEmacs.
  var y = offset.y
  let leftStart = offset.x
  let rightStart = offset.x + max(size.w, space.w.u)
  while true:
    var left = leftStart
    var right = rightStart
    var miny = high(LayoutUnit)
    let cy2 = y + size.h
    for ex in bctx.exclusions:
      let ey2 = ex.offset.y + ex.size.h
      if cy2 >= ex.offset.y and y < ey2:
        let ex2 = ex.offset.x + ex.size.w
        if ex.t == FloatLeft and left < ex2:
          left = ex2
        if ex.t == FloatRight and right > ex.offset.x:
          right = ex.offset.x
        miny = min(ey2, miny)
    let w = right - left
    if w >= size.w or miny == high(LayoutUnit):
      # Enough space, or no other exclusions found at this y offset.
      outw = w
      if float == FloatLeft:
        return offset(x = left, y = y)
      else: # FloatRight
        return offset(x = right - size.w, y = y)
    # Move y to the bottom exclusion edge at the lowest y (where the exclusion
    # still intersects with the previous y).
    y = miny
  assert false

func findNextFloatOffset(bctx: BlockContext; offset: Offset; size: Size;
    space: AvailableSpace; float: CSSFloat): Offset =
  var dummy: LayoutUnit
  return bctx.findNextFloatOffset(offset, size, space, float, dummy)

func findNextBlockOffset(bctx: BlockContext; offset: Offset; size: Size;
    space: AvailableSpace; outw: var LayoutUnit): Offset =
  return bctx.findNextFloatOffset(offset, size, space, FloatLeft, outw)

proc positionFloat(bctx: var BlockContext; child: BlockBox;
    space: AvailableSpace; bfcOffset: Offset) =
  let clear = child.computed{"clear"}
  if clear != ClearNone:
    child.offset.clearFloats(bctx, clear)
  let size = size(
    w = child.margin.left + child.margin.right + child.size.w,
    h = child.margin.top + child.margin.bottom + child.size.h
  )
  let childBfcOffset = offset(
    x = bfcOffset.x + child.offset.x - child.margin.left,
    y = max(bfcOffset.y + child.offset.y - child.margin.top, bctx.clearOffset)
  )
  assert space.w.t != scFitContent
  let ft = child.computed{"float"}
  assert ft != FloatNone
  let offset = bctx.findNextFloatOffset(childBfcOffset, size, space, ft)
  child.offset = offset(
    x = offset.x - bfcOffset.x + child.margin.left,
    y = offset.y - bfcOffset.y + child.margin.top
  )
  let ex = Exclusion(offset: offset, size: size, t: ft)
  bctx.exclusions.add(ex)
  bctx.maxFloatHeight = max(bctx.maxFloatHeight, ex.offset.y + ex.size.h)

proc positionFloats(bctx: var BlockContext) =
  for f in bctx.unpositionedFloats:
    bctx.positionFloat(f.box, f.space, f.parentBps.offset)
  bctx.unpositionedFloats.setLen(0)

const RowGroupBox = {
  DisplayTableRowGroup, DisplayTableHeaderGroup, DisplayTableFooterGroup
}

proc layoutFlow(bctx: var BlockContext; box: BlockBox; builder: BlockBoxBuilder;
    sizes: ResolvedSizes) =
  if builder.canFlushMargins(sizes):
    bctx.flushMargins(box)
    bctx.positionFloats()
  if builder.computed{"clear"} != ClearNone:
    box.offset.clearFloats(bctx, builder.computed{"clear"})
  if builder.inlinelayout:
    # Builder only contains inline boxes.
    bctx.layoutInline(box, builder.children, sizes)
  else:
    # Builder only contains block boxes.
    bctx.layoutBlock(box, builder, sizes)

proc layoutListItem(bctx: var BlockContext; box: BlockBox;
    builder: ListItemBoxBuilder; sizes: ResolvedSizes) =
  if builder.marker != nil:
    # wrap marker + main box in a new box
    let innerBox = BlockBox(
      computed: builder.content.computed,
      node: builder.node,
      offset: box.offset,
      margin: sizes.margin,
      positioned: sizes.positioned
    )
    bctx.layoutFlow(innerBox, builder.content, sizes)
    #TODO we should put markers right before the first atom of the parent
    # list item or something...
    var bctx = BlockContext(lctx: bctx.lctx)
    let children = @[BoxBuilder(builder.marker)]
    let space = availableSpace(w = fitContent(sizes.space.w), h = sizes.space.h)
    let markerInline = bctx.layoutRootInline(children, space,
      builder.marker.computed, offset(x = 0, y = 0), offset(x = 0, y = 0))
    let marker = BlockBox(
      computed: builder.marker.computed,
      inline: markerInline,
      size: markerInline.size,
      offset: offset(x = -markerInline.size.w, y = 0),
      xminwidth: markerInline.xminwidth
    )
    # take inner box min width etc.
    box.xminwidth = innerBox.xminwidth
    box.baseline = innerBox.baseline
    box.firstBaseline = innerBox.firstBaseline
    box.size = innerBox.size
    # move innerBox margin & offset to outer box
    box.offset = innerBox.offset
    box.margin = innerBox.margin
    box.positioned = innerBox.positioned
    innerBox.offset = offset(x = 0, y = 0)
    innerBox.margin = RelativeRect()
    innerBox.positioned = RelativeRect()
    box.nested = @[marker, innerBox]
  else:
    bctx.layoutFlow(box, builder.content, sizes)

# parentWidth, parentHeight: width/height of the containing block.
proc addInlineBlock(ictx: var InlineContext; state: var InlineState;
    builder: BlockBoxBuilder; parentWidth, parentHeight: SizeConstraint) =
  let lctx = ictx.lctx
  let percHeight = parentHeight.toPercSize()
  let space = availableSpace(w = parentWidth, h = maxContent())
  let sizes = lctx.resolveFloatSizes(space, percHeight, builder.computed)
  let box = BlockBox(
    computed: builder.computed,
    node: builder.node,
    margin: sizes.margin,
    positioned: sizes.positioned
  )
  var bctx = BlockContext(lctx: lctx)
  bctx.marginTodo.append(sizes.margin.top)
  case builder.computed{"display"}
  of DisplayInlineBlock:
    bctx.layoutFlow(box, builder, sizes)
  of DisplayInlineTable:
    bctx.layoutTable(box, TableBoxBuilder(builder), sizes)
  of DisplayInlineFlex:
    bctx.layoutFlex(box, builder, sizes)
  else:
    assert false, $builder.computed{"display"}
  assert bctx.unpositionedFloats.len == 0
  bctx.marginTodo.append(sizes.margin.bottom)
  let marginTop = box.offset.y
  let marginBottom = bctx.marginTodo.sum()
  # If the highest float edge is higher than the box itself, set that as
  # the box height.
  if bctx.maxFloatHeight > box.size.h + marginBottom:
    box.size.h = bctx.maxFloatHeight - marginBottom
  box.offset.y = 0
  # Apply the block box's properties to the atom itself.
  let iblock = InlineAtom(
    t: iatInlineBlock,
    innerbox: box,
    offset: offset(x = sizes.margin.left, y = 0),
    size: size(
      w = box.size.w + sizes.margin.left + sizes.margin.right,
      h = box.size.h
    )
  )
  let iastate = InlineAtomState(
    baseline: box.baseline,
    vertalign: builder.computed{"vertical-align"},
    marginTop: marginTop,
    marginBottom: bctx.marginTodo.sum()
  )
  discard ictx.addAtom(state, iastate, iblock)
  ictx.whitespacenum = 0

proc layoutChildren(ictx: var InlineContext; state: var InlineState;
    children: seq[BoxBuilder]) =
  for child in children:
    case child.computed{"display"}
    of DisplayInline:
      let child = ictx.layoutInline(InlineBoxBuilder(child))
      state.fragment.children.add(child)
    of DisplayInlineBlock, DisplayInlineTable, DisplayInlineFlex:
      # Note: we do not need a separate inline fragment here, because the tree
      # generator already does an iflush() before adding inline blocks.
      let w = fitContent(ictx.space.w)
      let h = ictx.space.h
      ictx.addInlineBlock(state, BlockBoxBuilder(child), w, h)
    else:
      assert false, "child.t is " & $child.computed{"display"}

proc layoutInline(ictx: var InlineContext; box: InlineBoxBuilder):
    InlineFragment =
  let lctx = ictx.lctx
  let fragment = InlineFragment(
    computed: box.computed,
    node: box.node,
    splitType: box.splitType
  )
  if stSplitStart in box.splitType:
    let marginLeft = box.computed{"margin-left"}.px(lctx, ictx.space.w)
    ictx.currentLine.size.w += marginLeft
  var state = InlineState(
    computed: box.computed,
    node: box.node,
    fragment: fragment,
    firstLine: true,
    startOffsetTop: offset(
      x = ictx.currentLine.widthAfterWhitespace,
      y = ictx.currentLine.offsety
    )
  )
  if box.newline:
    ictx.flushLine(state)
  if stSplitStart in box.splitType:
    let paddingLeft = box.computed{"padding-left"}.px(lctx, ictx.space.w)
    ictx.currentLine.size.w += paddingLeft
  assert box.children.len == 0 or box.text.len == 0
  ictx.applyLineHeight(ictx.currentLine, state.computed)
  if ictx.firstTextFragment == nil:
    ictx.firstTextFragment = fragment
  ictx.lastTextFragment = fragment
  if box.bmp != nil:
    let h = int(box.bmp.height).toLayoutUnit().ceilTo(ictx.cellheight)
    let iastate = InlineAtomState(
      vertalign: state.computed{"vertical-align"},
      baseline: h
    )
    let atom = InlineAtom(
      t: iatImage,
      bmp: box.bmp,
      size: size(w = int(box.bmp.width), h = h), #TODO overflow
    )
    discard ictx.addAtom(state, iastate, atom)
  else:
    ictx.layoutText(state, box.text)
    ictx.layoutChildren(state, box.children)
  if stSplitEnd in box.splitType:
    let paddingRight = box.computed{"padding-right"}.px(lctx, ictx.space.w)
    ictx.currentLine.size.w += paddingRight
    let marginRight = box.computed{"margin-right"}.px(lctx, ictx.space.w)
    ictx.currentLine.size.w += marginRight
  if state.firstLine:
    fragment.startOffset = offset(
      x = state.startOffsetTop.x,
      y = ictx.currentLine.offsety
    )
  else:
    fragment.startOffset = offset(x = 0, y = ictx.currentLine.offsety)
  return fragment

proc layoutRootInline(bctx: var BlockContext; inlines: seq[BoxBuilder];
    space: AvailableSpace; computed: CSSComputedValues;
    offset, bfcOffset: Offset): RootInlineFragment =
  let root = RootInlineFragment(
    offset: offset,
    fragment: InlineFragment(computed: bctx.lctx.myRootProperties)
  )
  var ictx = bctx.initInlineContext(space, bfcOffset, root)
  for child in inlines:
    assert child.computed{"display"} == DisplayInline, "display is " &
      $child.computed{"display"}
    let childFragment = ictx.layoutInline(InlineBoxBuilder(child))
    root.fragment.children.add(childFragment)
  if ictx.firstTextFragment != nil:
    root.fragment.startOffset = ictx.firstTextFragment.startOffset
  let lastFragment = if ictx.lastTextFragment != nil:
    ictx.lastTextFragment
  else:
    InlineFragment(computed: computed)
  var state = InlineState(computed: computed, fragment: lastFragment)
  ictx.finishLine(state, wrap = false)
  ictx.horizontalAlignLines(state)
  ictx.addBackgroundAreas(root.fragment)
  root.xminwidth = ictx.minwidth
  return root

proc positionAbsolute(lctx: LayoutState; box: BlockBox; margin: RelativeRect) =
  let last = lctx.positioned[^1]
  let left = box.computed{"left"}
  let right = box.computed{"right"}
  let top = box.computed{"top"}
  let bottom = box.computed{"bottom"}
  let parentWidth = applySizeConstraint(lctx.attrs.width_px, last.w)
  let parentHeight = applySizeConstraint(lctx.attrs.height_px, last.h)
  if not left.auto:
    box.offset.x = box.positioned.left
    box.offset.x += margin.left
  elif not right.auto:
    box.offset.x = parentWidth - box.positioned.right - box.size.w
    box.offset.x -= margin.right
  if not top.auto:
    box.offset.y = box.positioned.top
    box.offset.y += margin.top
  elif not bottom.auto:
    box.offset.y = parentHeight - box.positioned.bottom - box.size.h
    box.offset.y -= margin.bottom

proc positionRelative(parent, box: BlockBox) =
  if not box.computed{"left"}.auto:
    box.offset.x += box.positioned.left
  elif not box.computed{"right"}.auto:
    box.offset.x += parent.size.w - box.positioned.right - box.size.w
  if not box.computed{"top"}.auto:
    box.offset.y += box.positioned.top
  elif not box.computed{"bottom"}.auto:
    box.offset.y += parent.size.h - box.positioned.bottom - box.size.h

const ProperTableChild = RowGroupBox + {
  DisplayTableRow, DisplayTableColumn, DisplayTableColumnGroup,
  DisplayTableCaption
}
const ProperTableRowParent = RowGroupBox + {
  DisplayTable, DisplayInlineTable
}

type
  CellWrapper = ref object
    builder: TableCellBoxBuilder
    box: BlockBox
    coli: int
    colspan: int
    rowspan: int
    reflow: bool
    grown: int # number of remaining rows
    real: CellWrapper # for filler wrappers
    last: bool # is this the last filler?
    height: LayoutUnit
    baseline: LayoutUnit

  RowContext = object
    cells: seq[CellWrapper]
    reflow: seq[bool]
    width: LayoutUnit
    height: LayoutUnit
    builder: TableRowBoxBuilder
    ncols: int

  ColumnContext = object
    minwidth: LayoutUnit
    width: LayoutUnit
    wspecified: bool
    reflow: bool
    weight: float64

  TableContext = object
    lctx: LayoutState
    caption: TableCaptionBoxBuilder
    rows: seq[RowContext]
    cols: seq[ColumnContext]
    growing: seq[CellWrapper]
    maxwidth: LayoutUnit
    blockSpacing: LayoutUnit
    inlineSpacing: LayoutUnit
    space: AvailableSpace # space we got from parent

proc layoutTableCell(lctx: LayoutState; builder: TableCellBoxBuilder;
    space: AvailableSpace): BlockBox =
  var sizes = ResolvedSizes(
    padding: resolvePadding(space.w, lctx, builder.computed),
    space: space,
    minMaxSizes: [dtHorizontal: DefaultSpan, dtVertical: DefaultSpan]
  )
  if sizes.space.w.isDefinite():
    sizes.space.w.u -= sizes.padding.left
    sizes.space.w.u -= sizes.padding.right
  if sizes.space.h.isDefinite():
    sizes.space.h.u -= sizes.padding.top
    sizes.space.h.u -= sizes.padding.bottom
  let box = BlockBox(
    computed: builder.computed,
    node: builder.node,
    margin: sizes.margin,
    positioned: sizes.positioned
  )
  var bctx = BlockContext(lctx: lctx)
  bctx.layoutFlow(box, builder, sizes)
  assert bctx.unpositionedFloats.len == 0
  # Table cells ignore margins.
  box.offset.y = 0
  # If the highest float edge is higher than the box itself, set that as
  # the box height.
  box.size.h = max(box.size.h, bctx.maxFloatHeight)
  return box

# Sort growing cells, and filter out cells that have grown to their intended
# rowspan.
proc sortGrowing(pctx: var TableContext) =
  var i = 0
  for j, cellw in pctx.growing:
    if pctx.growing[i].grown == 0:
      continue
    if j != i:
      pctx.growing[i] = cellw
    inc i
  pctx.growing.setLen(i)
  pctx.growing.sort(proc(a, b: CellWrapper): int = cmp(a.coli, b.coli))

# Grow cells with a rowspan > 1 (to occupy their place in a new row).
proc growRowspan(pctx: var TableContext; ctx: var RowContext;
    growi, i, n: var int; growlen: int) =
  while growi < growlen:
    let cellw = pctx.growing[growi]
    if cellw.coli > n:
      break
    dec cellw.grown
    let rowspanFiller = CellWrapper(
      colspan: cellw.colspan,
      rowspan: cellw.rowspan,
      coli: n,
      real: cellw,
      last: cellw.grown == 0
    )
    ctx.cells.add(nil)
    ctx.cells[i] = rowspanFiller
    for i in n ..< n + cellw.colspan:
      ctx.width += pctx.cols[i].width
      ctx.width += pctx.inlineSpacing * 2
    n += cellw.colspan
    inc i
    inc growi

proc preBuildTableRow(pctx: var TableContext; box: TableRowBoxBuilder;
    parent: BlockBox; rowi, numrows: int): RowContext =
  var ctx = RowContext(
    builder: box,
    cells: newSeq[CellWrapper](box.children.len)
  )
  var n = 0
  var i = 0
  var growi = 0
  # this increases in the loop, but we only want to check growing cells that
  # were added by previous rows.
  let growlen = pctx.growing.len
  for child in box.children:
    pctx.growRowspan(ctx, growi, i, n, growlen)
    assert child.computed{"display"} == DisplayTableCell
    let cellbuilder = TableCellBoxBuilder(child)
    let colspan = cellbuilder.computed{"-cha-colspan"}
    let rowspan = min(cellbuilder.computed{"-cha-rowspan"}, numrows - rowi)
    let cw = cellbuilder.computed{"width"}
    let ch = cellbuilder.computed{"height"}
    let space = availableSpace(
      w = cw.stretchOrMaxContent(pctx.lctx, pctx.space.w),
      h = ch.stretchOrMaxContent(pctx.lctx, pctx.space.h)
    )
    #TODO specified table height should be distributed among rows.
    # Allow the table cell to use its specified width.
    let box = pctx.lctx.layoutTableCell(cellbuilder, space)
    let wrapper = CellWrapper(
      box: box,
      builder: cellbuilder,
      colspan: colspan,
      rowspan: rowspan,
      coli: n
    )
    ctx.cells[i] = wrapper
    if rowspan > 1:
      pctx.growing.add(wrapper)
      wrapper.grown = rowspan - 1
    if pctx.cols.len < n + colspan:
      pctx.cols.setLen(n + colspan)
    if ctx.reflow.len < n + colspan:
      ctx.reflow.setLen(n + colspan)
    let minw = box.xminwidth div colspan
    let w = box.size.w div colspan
    for i in n ..< n + colspan:
      # Add spacing.
      ctx.width += pctx.inlineSpacing
      # Figure out this cell's effect on the column's width.
      # Four cases exits:
      # 1. colwidth already fixed, cell width is fixed: take maximum
      # 2. colwidth already fixed, cell width is auto: take colwidth
      # 3. colwidth is not fixed, cell width is fixed: take cell width
      # 4. neither of colwidth or cell width are fixed: take maximum
      if ctx.reflow.len <= i: ctx.reflow.setLen(i + 1)
      if pctx.cols[i].wspecified:
        if space.w.isDefinite():
          # A specified column already exists; we take the larger width.
          if w > pctx.cols[i].width:
            pctx.cols[i].width = w
            ctx.reflow[i] = true
        if pctx.cols[i].width != w:
          wrapper.reflow = true
      else:
        if space.w.isDefinite():
          # This is the first specified column. Replace colwidth with whatever
          # we have.
          ctx.reflow[i] = true
          pctx.cols[i].wspecified = true
          pctx.cols[i].width = w
        else:
          if w > pctx.cols[i].width:
            pctx.cols[i].width = w
            ctx.reflow[i] = true
          else:
            wrapper.reflow = true
      if pctx.cols[i].minwidth < minw:
        pctx.cols[i].minwidth = minw
        if pctx.cols[i].width < minw:
          pctx.cols[i].width = minw
          ctx.reflow[i] = true
      ctx.width += pctx.cols[i].width
      # Add spacing to the right side.
      ctx.width += pctx.inlineSpacing
    n += colspan
    inc i
  pctx.growRowspan(ctx, growi, i, n, growlen)
  pctx.sortGrowing()
  when defined(debug):
    for cell in ctx.cells:
      assert cell != nil
  ctx.ncols = n
  return ctx

proc alignTableCell(cell: BlockBox; availableHeight, baseline: LayoutUnit) =
  case cell.computed{"vertical-align"}.keyword
  of VerticalAlignTop:
    cell.offset.y = 0
  of VerticalAlignMiddle:
    cell.offset.y = availableHeight div 2 - cell.size.h div 2
  of VerticalAlignBottom:
    cell.offset.y = availableHeight - cell.size.h
  else:
    cell.offset.y = baseline - cell.firstBaseline

proc layoutTableRow(pctx: TableContext; ctx: RowContext; parent: BlockBox;
    builder: TableRowBoxBuilder): BlockBox =
  var x: LayoutUnit = 0
  var n = 0
  let row = BlockBox(
    computed: builder.computed,
    node: builder.node
  )
  var baseline: LayoutUnit = 0
  # real cellwrappers of fillers
  var to_align: seq[CellWrapper]
  # cells with rowspan > 1 that must store baseline
  var to_baseline: seq[CellWrapper]
  # cells that we must update row height of
  var to_height: seq[CellWrapper]
  for cellw in ctx.cells:
    var w: LayoutUnit = 0
    for i in n ..< n + cellw.colspan:
      w += pctx.cols[i].width
    # Add inline spacing for merged columns.
    w += pctx.inlineSpacing * (cellw.colspan - 1) * 2
    if cellw.reflow and cellw.builder != nil:
      # Do not allow the table cell to make use of its specified width.
      # e.g. in the following table
      # <TABLE>
      # <TR>
      # <TD style="width: 5ch" bgcolor=blue>5ch</TD>
      # </TR>
      # <TR>
      # <TD style="width: 9ch" bgcolor=red>9ch</TD>
      # </TR>
      # </TABLE>
      # the TD with a width of 5ch should be 9ch wide as well.
      let space = availableSpace(w = stretch(w), h = maxContent())
      cellw.box = pctx.lctx.layoutTableCell(cellw.builder, space)
      w = max(w, cellw.box.size.w)
    let cell = cellw.box
    x += pctx.inlineSpacing
    if cell != nil:
      cell.offset.x += x
    x += pctx.inlineSpacing
    x += w
    n += cellw.colspan
    const HasNoBaseline = {
      VerticalAlignTop, VerticalAlignMiddle, VerticalAlignBottom
    }
    if cell != nil:
      if cell.computed{"vertical-align"}.keyword notin HasNoBaseline: # baseline
        baseline = max(cell.firstBaseline, baseline)
        if cellw.rowspan > 1:
          to_baseline.add(cellw)
      row.nested.add(cell)
      if cellw.rowspan > 1:
        to_height.add(cellw)
      row.size.h = max(row.size.h, cell.size.h div cellw.rowspan)
    else:
      let real = cellw.real
      row.size.h = max(row.size.h, real.box.size.h div cellw.rowspan)
      to_height.add(real)
      if cellw.last:
        to_align.add(real)
  for cellw in to_height:
    cellw.height += row.size.h
  for cellw in to_baseline:
    cellw.baseline = baseline
  for cellw in to_align:
    alignTableCell(cellw.box, cellw.height, cellw.baseline)
  for cell in row.nested:
    alignTableCell(cell, row.size.h, baseline)
  row.size.w = x
  return row

proc preBuildTableRows(ctx: var TableContext; rows: seq[TableRowBoxBuilder];
    table: BlockBox) =
  for i, row in rows:
    let rctx = ctx.preBuildTableRow(row, table, i, rows.len)
    ctx.rows.add(rctx)
    ctx.maxwidth = max(rctx.width, ctx.maxwidth)

proc preBuildTableRows(ctx: var TableContext; builder: TableBoxBuilder;
    table: BlockBox) =
  # Use separate seqs for different row groups, so that e.g. this HTML:
  # echo '<TABLE><TBODY><TR><TD>world<THEAD><TR><TD>hello'|cha -T text/html
  # is rendered as:
  # hello
  # world
  var thead: seq[TableRowBoxBuilder] = @[]
  var tbody: seq[TableRowBoxBuilder] = @[]
  var tfoot: seq[TableRowBoxBuilder] = @[]
  var caption: TableCaptionBoxBuilder
  for child in builder.children:
    assert child.computed{"display"} in ProperTableChild
    case child.computed{"display"}
    of DisplayTableRow:
      tbody.add(TableRowBoxBuilder(child))
    of DisplayTableHeaderGroup:
      for child in child.children:
        assert child.computed{"display"} == DisplayTableRow
        thead.add(TableRowBoxBuilder(child))
    of DisplayTableRowGroup:
      for child in child.children:
        assert child.computed{"display"} == DisplayTableRow
        tbody.add(TableRowBoxBuilder(child))
    of DisplayTableFooterGroup:
      for child in child.children:
        assert child.computed{"display"} == DisplayTableRow
        tfoot.add(TableRowBoxBuilder(child))
    of DisplayTableCaption:
      if caption == nil:
        caption = TableCaptionBoxBuilder(child)
    else: discard
  if caption != nil:
    ctx.caption = caption
  ctx.preBuildTableRows(thead, table)
  ctx.preBuildTableRows(tbody, table)
  ctx.preBuildTableRows(tfoot, table)

func calcSpecifiedRatio(ctx: TableContext; W: LayoutUnit): LayoutUnit =
  var totalSpecified: LayoutUnit = 0
  var hasUnspecified = false
  for col in ctx.cols:
    if col.wspecified:
      totalSpecified += col.width
    else:
      hasUnspecified = true
      totalSpecified += col.minwidth
  # Only grow specified columns if no unspecified column exists to take the
  # rest of the space.
  if totalSpecified == 0 or W > totalSpecified and hasUnspecified:
    return 1
  return W / totalSpecified

proc calcUnspecifiedColIndices(ctx: var TableContext; W: var LayoutUnit;
    weight: var float64): seq[int] =
  let specifiedRatio = ctx.calcSpecifiedRatio(W)
  # Spacing for each column:
  var avail = newSeqUninitialized[int](ctx.cols.len)
  var j = 0
  for i, col in ctx.cols.mpairs:
    if not col.wspecified:
      avail[j] = i
      let w = if col.width < W:
        toFloat64(col.width)
      else:
        toFloat64(W) * (ln(toFloat64(col.width) / toFloat64(W)) + 1)
      col.weight = w
      weight += w
      inc j
    else:
      if specifiedRatio != 1:
        col.width *= specifiedRatio
        col.reflow = true
      W -= col.width
      avail.del(j)
  return avail

func needsRedistribution(ctx: TableContext; computed: CSSComputedValues): bool =
  case ctx.space.w.t
  of scMinContent, scMaxContent:
    return false
  of scStretch:
    return ctx.space.w.u != ctx.maxwidth
  of scFitContent:
    let u = ctx.space.w.u
    return u > ctx.maxwidth and not computed{"width"}.auto or u < ctx.maxwidth

proc redistributeWidth(ctx: var TableContext) =
  # Remove inline spacing from distributable width.
  var W = ctx.space.w.u - ctx.cols.len * ctx.inlineSpacing * 2
  var weight = 0f64
  var avail = ctx.calcUnspecifiedColIndices(W, weight)
  var redo = true
  while redo and avail.len > 0 and weight != 0:
    if weight == 0: break # zero weight; nothing to distribute
    if W < 0:
      W = 0
    redo = false
    # divide delta width by sum of ln(width) for all elem in avail
    let unit = toFloat64(W) / weight
    weight = 0
    for i in countdown(avail.high, 0):
      let j = avail[i]
      let x = unit * ctx.cols[j].weight
      let mw = ctx.cols[j].minwidth
      ctx.cols[j].width = x
      if mw > x:
        W -= mw
        ctx.cols[j].width = mw
        avail.del(i)
        redo = true
      else:
        weight += ctx.cols[j].weight
      ctx.cols[j].reflow = true

proc reflowTableCells(ctx: var TableContext) =
  for i in countdown(ctx.rows.high, 0):
    var row = addr ctx.rows[i]
    var n = ctx.cols.len - 1
    for j in countdown(row.cells.high, 0):
      let m = n - row.cells[j].colspan
      while n > m:
        if ctx.cols[n].reflow:
          row.cells[j].reflow = true
        if n < row.reflow.len and row.reflow[n]:
          ctx.cols[n].reflow = true
        dec n

proc layoutTableRows(ctx: TableContext; table: BlockBox; sizes: ResolvedSizes) =
  var y: LayoutUnit = 0
  for roww in ctx.rows:
    if roww.builder.computed{"visibility"} == VisibilityCollapse:
      continue
    y += ctx.blockSpacing
    let row = ctx.layoutTableRow(roww, table, roww.builder)
    row.offset.y += y
    row.offset.x += sizes.padding.left
    row.size.w += sizes.padding.left
    row.size.w += sizes.padding.right
    y += ctx.blockSpacing
    y += row.size.h
    table.nested.add(row)
    table.size.w = max(row.size.w, table.size.w)
  table.size.h = applySizeConstraint(y, sizes.space.h)

proc addTableCaption(ctx: TableContext; table: BlockBox) =
  let percHeight = ctx.space.h.toPercSize()
  let space = availableSpace(w = stretch(table.size.w), h = maxContent())
  let builder = ctx.caption
  let sizes = ctx.lctx.resolveSizes(space, percHeight, builder.computed)
  let box = BlockBox(
    computed: builder.computed,
    node: builder.node,
    margin: sizes.margin,
    positioned: sizes.positioned
  )
  var bctx = BlockContext(lctx: ctx.lctx)
  bctx.layoutFlow(box, builder, sizes)
  assert bctx.unpositionedFloats.len == 0
  let outerHeight = box.offset.y + box.size.h + bctx.marginTodo.sum()
  table.size.h += outerHeight
  table.size.w = max(table.size.w, box.size.w)
  case builder.computed{"caption-side"}
  of CaptionSideTop, CaptionSideBlockStart:
    for r in table.nested:
      r.offset.y += outerHeight
    table.nested.insert(box, 0)
  of CaptionSideBottom, CaptionSideBlockEnd:
    box.offset.y += outerHeight
    table.nested.add(box)

# Table layout. We try to emulate w3m's behavior here:
# 1. Calculate minimum and preferred width of each column
# 2. If column width is not auto, set width to max(min_col_width, specified)
# 3. Calculate the maximum preferred row width. If this is
# a) less than the specified table width, or
# b) greater than the table's content width:
#      Distribute the table's content width among cells with an unspecified
#      width. If this would give any cell a width < min_width, set that
#      cell's width to min_width, then re-do the distribution.
proc layoutTable(bctx: BlockContext; table: BlockBox; builder: TableBoxBuilder;
    sizes: ResolvedSizes) =
  let lctx = bctx.lctx
  var ctx = TableContext(lctx: lctx, space: sizes.space)
  if table.computed{"border-collapse"} != BorderCollapseCollapse:
    ctx.inlineSpacing = table.computed{"border-spacing"}.a.px(lctx)
    ctx.blockSpacing = table.computed{"border-spacing"}.b.px(lctx)
  ctx.preBuildTableRows(builder, table)
  if ctx.needsRedistribution(table.computed):
    ctx.redistributeWidth()
  for col in ctx.cols:
    table.size.w += col.width
  ctx.reflowTableCells()
  ctx.layoutTableRows(table, sizes)
  if ctx.caption != nil:
    ctx.addTableCaption(table)

proc postAlignChild(box, child: BlockBox; width: LayoutUnit) =
  case box.computed{"text-align"}
  of TextAlignChaCenter:
    child.offset.x += max(width div 2 - child.size.w div 2, 0)
  of TextAlignChaRight:
    child.offset.x += max(width - child.size.w - child.margin.right, 0)
  of TextAlignChaLeft:
    discard # default
  else:
    discard

proc layout(bctx: var BlockContext; box: BlockBox; builder: BoxBuilder;
    sizes: ResolvedSizes) =
  case builder.computed{"display"}
  of DisplayBlock, DisplayFlowRoot:
    bctx.layoutFlow(box, BlockBoxBuilder(builder), sizes)
  of DisplayListItem:
    bctx.layoutListItem(box, ListItemBoxBuilder(builder), sizes)
  of DisplayTable:
    bctx.layoutTable(box, TableBoxBuilder(builder), sizes)
  of DisplayFlex:
    bctx.layoutFlex(box, BlockBoxBuilder(builder), sizes)
  else:
    assert false, "builder.t is " & $builder.computed{"display"}

proc layoutFlexChild(lctx: LayoutState; builder: BoxBuilder;
    sizes: ResolvedSizes): BlockBox =
  var bctx = BlockContext(lctx: lctx)
  # note: we do not append margins here, since those belong to the flex item,
  # not its inner BFC.
  let box = BlockBox(
    computed: builder.computed,
    node: builder.node,
    offset: offset(x = sizes.margin.left, y = 0),
    margin: sizes.margin,
    positioned: sizes.positioned
  )
  bctx.layout(box, builder, sizes)
  assert bctx.unpositionedFloats.len == 0
  # If the highest float edge is higher than the box itself, set that as
  # the box height.
  if bctx.maxFloatHeight > box.offset.y + box.size.h:
    box.size.h = bctx.maxFloatHeight - box.offset.y
  return box

type
  FlexWeightType = enum
    fwtGrow, fwtShrink

  FlexPendingItem = object
    child: BlockBox
    builder: BoxBuilder
    weights: array[FlexWeightType, float64]
    sizes: ResolvedSizes

  FlexMainContext = object
    offset: Offset
    totalSize: Size
    maxSize: Size
    maxMargin: RelativeRect
    totalWeight: array[FlexWeightType, float64]
    lctx: LayoutState
    pending: seq[FlexPendingItem]

const FlexReverse = {FlexDirectionRowReverse, FlexDirectionColumnReverse}
const FlexRow = {FlexDirectionRow, FlexDirectionRowReverse}

func outerSize(box: BlockBox; dim: DimensionType): LayoutUnit =
  return box.margin.dimSum(dim) + box.size[dim]

proc updateMaxSizes(mctx: var FlexMainContext; child: BlockBox) =
  mctx.maxSize.w = max(mctx.maxSize.w, child.size.w)
  mctx.maxSize.h = max(mctx.maxSize.h, child.size.h)
  mctx.maxMargin.left = max(mctx.maxMargin.left, child.margin.left)
  mctx.maxMargin.right = max(mctx.maxMargin.right, child.margin.right)
  mctx.maxMargin.top = max(mctx.maxMargin.top, child.margin.top)
  mctx.maxMargin.bottom = max(mctx.maxMargin.bottom, child.margin.bottom)

proc redistributeMainSize(mctx: var FlexMainContext; sizes: ResolvedSizes;
    dim: DimensionType) =
  #TODO actually use flex-basis
  let lctx = mctx.lctx
  let odim = dim.opposite
  if sizes.space[dim].isDefinite:
    var diff = sizes.space[dim].u - mctx.totalSize[dim]
    let wt = if diff > 0: fwtGrow else: fwtShrink
    var totalWeight = mctx.totalWeight[wt]
    while (wt == fwtGrow and diff > 0 or wt == fwtShrink and diff < 0) and
        totalWeight > 0:
      mctx.maxSize[odim] = 0 # redo maxSize calculation; we only need height here
      let unit = diff / totalWeight
      # reset total weight & available diff for the next iteration (if there is
      # one)
      totalWeight = 0
      diff = 0
      for it in mctx.pending.mitems:
        let builder = it.builder
        if it.weights[wt] == 0:
          mctx.updateMaxSizes(it.child)
          continue
        var u = it.child.size[dim] + unit * it.weights[wt]
        # check for min/max violation
        var minu = it.sizes.minMaxSizes[dim].min
        if dim == dtHorizontal:
          minu = max(it.child.xminwidth, minu)
        if minu > u:
          # min violation
          if wt == fwtShrink: # freeze
            diff += u - minu
            it.weights[wt] = 0
          u = minu
        let maxu = it.sizes.minMaxSizes[dim].max
        if maxu < u:
          # max violation
          if wt == fwtGrow: # freeze
            diff += u - maxu
            it.weights[wt] = 0
          u = maxu
        it.sizes.space[dim] = stretch(u - it.sizes.padding.dimSum(dim))
        totalWeight += it.weights[wt]
        #TODO we should call this only on freeze, and then put another loop to
        # the end for non-freezed items
        it.child = lctx.layoutFlexChild(builder, it.sizes)
        mctx.updateMaxSizes(it.child)

proc flushMain(mctx: var FlexMainContext; box: BlockBox; sizes: ResolvedSizes;
    totalMaxSize: var Size; dim: DimensionType) =
  let odim = dim.opposite
  let lctx = mctx.lctx
  mctx.redistributeMainSize(sizes, dim)
  let h = mctx.maxSize[odim] + mctx.maxMargin.dimSum(odim)
  var offset = mctx.offset
  for it in mctx.pending.mitems:
    if it.child.size[odim] < h and not it.sizes.space[odim].isDefinite:
      # if the max height is greater than our height, then take max height
      # instead. (if the box's available height is definite, then this will
      # change nothing, so we skip it as an optimization.)
      it.sizes.space[odim] = stretch(h - it.sizes.margin.dimSum(odim))
      it.child = lctx.layoutFlexChild(it.builder, it.sizes)
    it.child.offset[dim] = it.child.offset[dim] + offset[dim]
    # margins are added here, since they belong to the flex item.
    it.child.offset[odim] = it.child.offset[odim] + offset[odim] +
      it.child.margin.dimStart(odim)
    offset[dim] += it.child.size[dim]
    box.nested.add(it.child)
  totalMaxSize[dim] = max(totalMaxSize[dim], offset[dim])
  mctx = FlexMainContext(
    lctx: mctx.lctx,
    offset: mctx.offset
  )
  mctx.offset[odim] = mctx.offset[odim] + h

proc layoutFlex(bctx: var BlockContext; box: BlockBox; builder: BlockBoxBuilder;
    sizes: ResolvedSizes) =
  assert not builder.inlinelayout
  let lctx = bctx.lctx
  var i = 0
  var mctx = FlexMainContext(lctx: lctx)
  let flexDir = builder.computed{"flex-direction"}
  let children = if builder.computed{"flex-direction"} in FlexReverse:
    builder.children.reversed()
  else:
    builder.children
  var totalMaxSize = size(w = 0, h = 0) #TODO find a better name for this
  let canWrap = box.computed{"flex-wrap"} != FlexWrapNowrap
  let percHeight = sizes.space.h.toPercSize()
  let dim = if flexDir in FlexRow: dtHorizontal else: dtVertical
  while i < children.len:
    let builder = children[i]
    var childSizes = lctx.resolveFloatSizes(sizes.space, percHeight,
      builder.computed)
    let flexBasis = builder.computed{"flex-basis"}
    if not flexBasis.auto:
      if flexDir in FlexRow:
        childSizes.space.w = stretch(flexBasis.px(lctx, sizes.space.w))
      else:
        childSizes.space.h = stretch(flexBasis.px(lctx, sizes.space.h))
    var child = lctx.layoutFlexChild(builder, childSizes)
    if not flexBasis.auto and childSizes.space.w.isDefinite and
        child.xminwidth > childSizes.space.w.u:
      # first pass gave us a box that is smaller than the minimum acceptable
      # width whatever reason; this may have happened because the initial flex
      # basis was e.g. 0.  Try to resize it to something more usable.
      # Note: this is a hack; we need it because we cheat with size resolution
      # by using the algorithm that was in fact designed for floats, and without
      # this hack layouts with a flex-base of 0 break down horribly.
      # (And we need flex-base because using auto wherever the two-value `flex'
      # shorthand is used breaks down even more horribly.)
      #TODO implement the standard size resolution properly
      childSizes.space.w = stretch(child.xminwidth)
      child = lctx.layoutFlexChild(builder, childSizes)
    if canWrap and (sizes.space[dim].t == scMinContent or
        sizes.space[dim].isDefinite and
        mctx.totalSize[dim] + child.size[dim] > sizes.space[dim].u):
      mctx.flushMain(box, sizes, totalMaxSize, dim)
    mctx.totalSize[dim] += child.outerSize(dim)
    mctx.updateMaxSizes(child)
    let grow = builder.computed{"flex-grow"}
    let shrink = builder.computed{"flex-shrink"}
    mctx.totalWeight[fwtGrow] += grow
    mctx.totalWeight[fwtShrink] += shrink
    mctx.pending.add(FlexPendingItem(
      child: child,
      builder: builder,
      weights: [grow, shrink],
      sizes: childSizes
    ))
    inc i # need to increment index here for needsGrow
  if mctx.pending.len > 0:
    mctx.flushMain(box, sizes, totalMaxSize, dim)
  box.applySize(sizes, totalMaxSize[dim], sizes.space, dim)
  box.applySize(sizes, mctx.offset[dim.opposite], sizes.space, dim.opposite)

# Build an outer block box inside an existing block formatting context.
proc layoutBlockChild(bctx: var BlockContext; builder: BoxBuilder;
    space: AvailableSpace; offset: Offset; appendMargins: bool): BlockBox =
  let percHeight = space.h.toPercSize()
  var space = availableSpace(
    w = space.w,
    h = maxContent() #TODO fit-content when clip
  )
  if builder.computed{"display"} == DisplayTable:
    space.w = fitContent(space.w)
  let sizes = bctx.lctx.resolveSizes(space, percHeight, builder.computed)
  if appendMargins:
    # for nested blocks that do not establish their own BFC, and thus take part
    # in margin collapsing.
    bctx.marginTodo.append(sizes.margin.top)
  let box = BlockBox(
    computed: builder.computed,
    node: builder.node,
    offset: offset(x = offset.x + sizes.margin.left, y = offset.y),
    margin: sizes.margin,
    positioned: sizes.positioned
  )
  bctx.layout(box, builder, sizes)
  if appendMargins:
    bctx.marginTodo.append(sizes.margin.bottom)
  return box

# Establish a new block formatting context and build a block box.
proc layoutRootBlock(lctx: LayoutState; builder: BoxBuilder;
    space: AvailableSpace; offset: Offset; marginBottomOut: var LayoutUnit):
    BlockBox =
  var bctx = BlockContext(lctx: lctx)
  let box = bctx.layoutBlockChild(builder, space, offset, appendMargins = false)
  assert bctx.unpositionedFloats.len == 0
  marginBottomOut = bctx.marginTodo.sum()
  # If the highest float edge is higher than the box itself, set that as
  # the box height.
  if bctx.maxFloatHeight > box.size.h + marginBottomOut:
    box.size.h = bctx.maxFloatHeight - marginBottomOut
  return box

proc initBlockPositionStates(state: var BlockState; bctx: var BlockContext;
    box: BlockBox) =
  let prevBps = bctx.ancestorsHead
  bctx.ancestorsHead = BlockPositionState(
    box: box,
    offset: state.offset,
    resolved: bctx.parentBps == nil
  )
  if prevBps != nil:
    prevBps.next = bctx.ancestorsHead
  if bctx.parentBps != nil:
    bctx.ancestorsHead.offset.x += bctx.parentBps.offset.x
    bctx.ancestorsHead.offset.y += bctx.parentBps.offset.y
    # If parentBps is not nil, then our starting position is not in a new
    # BFC -> we must add it to our BFC offset.
    bctx.ancestorsHead.offset.x += box.offset.x
    bctx.ancestorsHead.offset.y += box.offset.y
  if bctx.marginTarget == nil:
    bctx.marginTarget = bctx.ancestorsHead
  state.initialMarginTarget = bctx.marginTarget
  state.initialTargetOffset = bctx.marginTarget.offset
  if bctx.parentBps == nil:
    # We have just established a new BFC. Resolve the margins instantly.
    bctx.marginTarget = nil
  state.prevParentBps = bctx.parentBps
  bctx.parentBps = bctx.ancestorsHead
  state.initialParentOffset = bctx.parentBps.offset

func isParentResolved(state: BlockState; bctx: BlockContext): bool =
  return bctx.marginTarget != state.initialMarginTarget or
    state.prevParentBps != nil and state.prevParentBps.resolved

# Note: this does not include display types that cannot appear as block
# children.
func establishesBFC(computed: CSSComputedValues): bool =
  return computed{"float"} != FloatNone or
    computed{"position"} == PositionAbsolute or
    computed{"display"} in {DisplayFlowRoot, DisplayTable, DisplayFlex} or
    computed{"overflow"} notin {OverflowVisible, OverflowClip}
    #TODO contain, grid, multicol, column-span

# Layout and place all children in the block box.
# Box placement must occur during this pass, since child box layout in the
# same block formatting context depends on knowing where the box offset is
# (because of floats).
proc layoutBlockChildren(state: var BlockState; bctx: var BlockContext;
    children: seq[BoxBuilder]; parent: BlockBox) =
  for builder in children:
    var dy: LayoutUnit = 0 # delta
    var child: BlockBox
    let isfloat = builder.computed{"float"} != FloatNone
    let isinflow = builder.computed{"position"} != PositionAbsolute and
      not isfloat
    if builder.computed.establishesBFC():
      var marginBottomOut: LayoutUnit
      child = bctx.lctx.layoutRootBlock(builder, state.space, state.offset,
        marginBottomOut)
      # Do not collapse margins of elements that do not participate in
      # the flow.
      if isinflow:
        bctx.marginTodo.append(child.margin.top)
        bctx.flushMargins(child)
        bctx.positionFloats()
        bctx.marginTodo.append(child.margin.bottom)
        if bctx.exclusions.len > 0:
          # Consulting the standard for an important edge case... (abridged)
          #
          # > The border box of an element that establishes a new BFC must not
          # > overlap the margin box of any floats in the same BFC as the
          # > element itself. If necessary, implementations should clear the
          # > said element, but may place it adjacent to such floats if there
          # > is sufficient space. CSS2 does not define when a UA may put said
          # > element next to the float.
          #
          # ...as expected. Thanks for nothing.
          #
          # OK here's what we do:
          # * run a normal pass
          # * place the longest word (i.e. xminwidth) somewhere
          # * run another pass with the placement we got
          #
          # I suspect this breaks horribly on some layouts, but I don't care
          # enough to make this convoluted garbage even more complex.
          #
          # Note that we do this only for elements in the flow. FF yanks
          # absolutely positioned elements on top of floats, and so do we.
          let pbfcOffset = bctx.bfcOffset
          let bfcOffset = offset(
            x = pbfcOffset.x + child.offset.x,
            y = max(pbfcOffset.y + child.offset.y, bctx.clearOffset)
          )
          let minSize = size(w = child.xminwidth, h = bctx.lctx.attrs.ppl)
          var outw: LayoutUnit
          let offset = bctx.findNextBlockOffset(bfcOffset, minSize,
            state.space, outw)
          let space = availableSpace(w = stretch(outw), h = state.space.h)
          child = bctx.lctx.layoutRootBlock(builder, space, offset - pbfcOffset,
            marginBottomOut)
      else:
        child.offset.y += child.margin.top
        if state.isParentResolved(bctx):
          # If parent offset has been resolved, use marginTodo in this
          # float's initial offset.
          child.offset.y += bctx.marginTodo.sum()
      # delta y is difference between old and new offsets (margin-top), sum
      # of margin todo in bctx2 (margin-bottom) + height.
      dy = child.offset.y - state.offset.y + child.size.h + marginBottomOut
    else:
      child = bctx.layoutBlockChild(builder, state.space, state.offset,
        appendMargins = true)
      # delta y is difference between old and new offsets (margin-top),
      # plus height.
      dy = child.offset.y - state.offset.y + child.size.h
    let childWidth = child.margin.left + child.size.w + child.margin.right
    state.xminwidth = max(state.xminwidth, child.xminwidth)
    if child.computed{"position"} != PositionAbsolute and not isfloat:
      # Not absolute, and not a float.
      state.maxChildWidth = max(state.maxChildWidth, childWidth)
      state.offset.y += dy
    elif isfloat:
      if state.space.w.t == scFitContent:
        # Float position depends on the available width, but in this case
        # the parent width is not known.
        #
        # Set the "re-layout" flag, and skip this box.
        # (If child boxes with fit-content have floats, those will be
        # re-layouted too first, so we do not have to consider those here.)
        state.needsReLayout = true
        # Since we emulate max-content here, the float will not contribute to
        # maxChildWidth in this iteration; instead, its outer width will be
        # summed up in totalFloatWidth and added to maxChildWidth in
        # initReLayout.
        state.totalFloatWidth += child.size.w + child.margin.left +
          child.margin.right
        continue
      state.maxChildWidth = max(state.maxChildWidth, childWidth)
      # Two cases exist:
      # a) The float cannot be positioned, because `box' has not resolved
      #    its y offset yet. (e.g. if float comes before the first child,
      #    we do not know yet if said child will move our y offset with a
      #    margin-top value larger than ours.)
      #    In this case we put it in unpositionedFloats, and defer positioning
      #    until our y offset is resolved.
      # b) `box' has resolved its y offset, so the float can already
      #    be positioned.
      # We check whether our y offset has been positioned as follows:
      # * save marginTarget in BlockState at layoutBlock's start
      # * if our saved marginTarget and bctx's marginTarget no longer point
      #   to the same object, that means our (or an ancestor's) offset has
      #   been resolved, i.e. we can position floats already.
      if bctx.marginTarget != state.initialMarginTarget:
        # y offset resolved
        bctx.positionFloat(child, state.space, bctx.parentBps.offset)
      else:
        bctx.unpositionedFloats.add(UnpositionedFloat(
          space: state.space,
          parentBps: bctx.parentBps,
          box: child
        ))
    state.nested.add(child)

# Unlucky path, where we have floating blocks and a fit-content width.
# Reset marginTodo & the starting offset, and stretch the box to the
# max child width.
proc initReLayout(state: var BlockState; bctx: var BlockContext;
    box: BlockBox; sizes: ResolvedSizes) =
  bctx.marginTodo = state.oldMarginTodo
  # Note: we do not reset our own BlockPositionState's offset; we assume it
  # has already been resolved in the previous pass.
  # (If not, it won't be resolved in this pass either, so the following code
  # does not really change anything.)
  bctx.parentBps.next = nil
  if state.initialMarginTarget != bctx.marginTarget:
    # Reset the initial margin target to its previous state, and then set
    # it as the marginTarget again.
    # Two solutions exist:
    # a) Store the initial margin target offset, then restore it here. Seems
    #    clean, but it would require a linked list traversal to update all
    #    child margin positions.
    # b) Re-use the previous margin target offsets; they are guaranteed
    #    to remain the same, because out-of-flow elements (like floats) do not
    #    participate in margin resolution. We do this by setting the margin
    #    target to a dummy object, which is a small price to pay compared
    #    to solution a).
    bctx.marginTarget = BlockPositionState(
      # Use initialTargetOffset to emulate the BFC positioning of the
      # previous pass.
      offset: state.initialTargetOffset
    )
    # Set ancestorsHead to a dummy object. Rationale: see below.
    # Also set ancestorsHead as the dummy object, so next elements are
    # chained to that.
    bctx.ancestorsHead = bctx.marginTarget
  state.nested.setLen(0)
  bctx.exclusions.setLen(state.oldExclusionsLen)
  state.offset = offset(x = sizes.padding.left, y = sizes.padding.top)
  box.applyWidth(sizes, state.maxChildWidth + state.totalFloatWidth)
  state.space.w = stretch(box.size.w)

# Re-position the children.
# The x offset with a fit-content width depends on the parent box's width,
# so we cannot do this in the first pass.
proc repositionChildren(state: BlockState; box: BlockBox; lctx: LayoutState) =
  for child in state.nested:
    if child.computed{"position"} != PositionAbsolute:
      box.postAlignChild(child, box.size.w)
    case child.computed{"position"}
    of PositionRelative:
      box.positionRelative(child)
    of PositionAbsolute:
      lctx.positionAbsolute(child, child.margin)
    else: discard #TODO

proc layoutBlock(bctx: var BlockContext; box: BlockBox;
    builder: BlockBoxBuilder; sizes: ResolvedSizes) =
  let lctx = bctx.lctx
  let positioned = box.computed{"position"} notin {
    PositionStatic, PositionFixed, PositionSticky
  }
  if positioned:
    lctx.positioned.add(sizes.space)
  var state = BlockState(
    offset: offset(x = sizes.padding.left, y = sizes.padding.top),
    space: sizes.space,
    oldMarginTodo: bctx.marginTodo,
    oldExclusionsLen: bctx.exclusions.len
  )
  state.initBlockPositionStates(bctx, box)
  state.layoutBlockChildren(bctx, builder.children, box)
  if state.needsReLayout:
    state.initReLayout(bctx, box, sizes)
    state.layoutBlockChildren(bctx, builder.children, box)
  if state.nested.len > 0:
    let lastNested = state.nested[^1]
    box.baseline = lastNested.offset.y + lastNested.baseline
  # Apply width then move the inline offset of children that still need
  # further relative positioning.
  box.applyWidth(sizes, state.maxChildWidth, state.space)
  state.repositionChildren(box, lctx)
  # Set the inner height to the last y offset minus the starting offset
  # (that is, top padding).
  let innerHeight = state.offset.y - sizes.padding.top
  box.applyHeight(sizes, innerHeight)
  # Add padding; we cannot do this further up without influencing positioning.
  box.applyPadding(sizes.padding)
  # Pass down relevant data from state.
  box.nested = state.nested
  box.xminwidth = state.xminwidth
  if state.isParentResolved(bctx):
    # Our offset has already been resolved, ergo any margins in marginTodo will
    # be passed onto the next box. Set marginTarget to nil, so that if we
    # (or one of our ancestors) was still set as a marginTarget, it no
    # longer is.
    bctx.positionFloats()
    bctx.marginTarget = nil
  # Reset parentBps to the previous node.
  bctx.parentBps = state.prevParentBps
  if positioned:
    lctx.positioned.setLen(lctx.positioned.len - 1)

# Tree generation (1st pass)

proc newMarkerBox(computed: CSSComputedValues; listItemCounter: int):
    MarkerBoxBuilder =
  let computed = computed.inheritProperties()
  computed{"display"} = DisplayInline
  # Use pre, so the space at the end of the default markers isn't ignored.
  computed{"white-space"} = WhitespacePre
  return MarkerBoxBuilder(
    computed: computed,
    text: @[computed{"list-style-type"}.listMarker(listItemCounter)]
  )

type BlockGroup = object
  parent: BlockBoxBuilder
  boxes: seq[BoxBuilder]

type InnerBlockContext = object
  styledNode: StyledNode
  blockgroup: BlockGroup
  lctx: LayoutState
  ibox: InlineBoxBuilder
  iroot: InlineBoxBuilder
  anonRow: TableRowBoxBuilder
  anonTable: TableBoxBuilder
  quoteLevel: int
  listItemCounter: int
  listItemReset: bool
  parent: ptr InnerBlockContext
  inlineStack: seq[StyledNode]

proc add(blockgroup: var BlockGroup; box: BoxBuilder) {.inline.} =
  assert box.computed{"display"} in {DisplayInline, DisplayInlineTable,
    DisplayInlineBlock}, $box.computed{"display"}
  blockgroup.boxes.add(box)

proc flush(blockgroup: var BlockGroup) =
  if blockgroup.boxes.len > 0:
    assert blockgroup.parent.computed{"display"} != DisplayInline
    let computed = blockgroup.parent.computed.inheritProperties()
    computed{"display"} = DisplayBlock
    let bbox = BlockBoxBuilder(computed: computed)
    bbox.inlinelayout = true
    bbox.children = blockgroup.boxes
    blockgroup.parent.children.add(bbox)
    blockgroup.boxes.setLen(0)

# Don't generate empty anonymous inline blocks between block boxes
func canGenerateAnonymousInline(blockgroup: BlockGroup;
    computed: CSSComputedValues; str: string): bool =
  return blockgroup.boxes.len > 0 and
      blockgroup.boxes[^1].computed{"display"} == DisplayInline or
    computed.whitespacepre or not str.onlyWhitespace()

proc newBlockGroup(parent: BlockBoxBuilder): BlockGroup =
  assert parent.computed{"display"} != DisplayInline
  return BlockGroup(parent: parent)

proc generateTableBox(styledNode: StyledNode; lctx: LayoutState;
  parent: var InnerBlockContext): TableBoxBuilder
proc generateTableRowGroupBox(styledNode: StyledNode; lctx: LayoutState;
  parent: var InnerBlockContext): TableRowGroupBoxBuilder
proc generateTableRowBox(styledNode: StyledNode; lctx: LayoutState;
  parent: var InnerBlockContext): TableRowBoxBuilder
proc generateTableCellBox(styledNode: StyledNode; lctx: LayoutState;
  parent: var InnerBlockContext): TableCellBoxBuilder
proc generateTableCaptionBox(styledNode: StyledNode; lctx: LayoutState;
  parent: var InnerBlockContext): TableCaptionBoxBuilder
proc generateBlockBox(styledNode: StyledNode; lctx: LayoutState;
  marker = none(MarkerBoxBuilder), parent: ptr InnerBlockContext = nil):
  BlockBoxBuilder
proc generateFlexBox(styledNode: StyledNode; lctx: LayoutState;
  parent: ptr InnerBlockContext = nil): BlockBoxBuilder
proc generateInlineBoxes(ctx: var InnerBlockContext; styledNode: StyledNode)

proc generateBlockBox(pctx: var InnerBlockContext; styledNode: StyledNode;
    marker = none(MarkerBoxBuilder)): BlockBoxBuilder =
  return generateBlockBox(styledNode, pctx.lctx, marker, addr pctx)

proc generateFlexBox(pctx: var InnerBlockContext; styledNode: StyledNode):
    BlockBoxBuilder =
  return generateFlexBox(styledNode, pctx.lctx, addr pctx)

proc flushTableRow(ctx: var InnerBlockContext) =
  if ctx.anonRow != nil:
    if ctx.blockgroup.parent.computed{"display"} == DisplayTableRow:
      ctx.blockgroup.parent.children.add(ctx.anonRow)
    else:
      if ctx.anonTable == nil:
        var wrappervals = ctx.styledNode.computed.inheritProperties()
        wrappervals{"display"} = DisplayTable
        ctx.anonTable = TableBoxBuilder(computed: wrappervals)
      ctx.anonTable.children.add(ctx.anonRow)
    ctx.anonRow = nil

proc flushTable(ctx: var InnerBlockContext) =
  ctx.flushTableRow()
  if ctx.anonTable != nil:
    ctx.blockgroup.parent.children.add(ctx.anonTable)

proc iflush(ctx: var InnerBlockContext) =
  if ctx.iroot != nil:
    assert ctx.iroot.computed{"display"} in {DisplayInline, DisplayInlineBlock,
      DisplayInlineTable, DisplayInlineFlex}
    ctx.blockgroup.add(ctx.iroot)
    ctx.iroot = nil
    ctx.ibox = nil

proc bflush(ctx: var InnerBlockContext) =
  ctx.iflush()
  ctx.blockgroup.flush()

proc flushInherit(ctx: var InnerBlockContext) =
  if ctx.parent != nil:
    if not ctx.listItemReset:
      ctx.parent.listItemCounter = ctx.listItemCounter
    ctx.parent.quoteLevel = ctx.quoteLevel

proc flush(ctx: var InnerBlockContext) =
  ctx.blockgroup.flush()
  ctx.flushTableRow()
  ctx.flushTable()
  ctx.flushInherit()

proc reconstructInlineParents(ctx: var InnerBlockContext): InlineBoxBuilder =
  let rootNode = ctx.inlineStack[0]
  var parent = InlineBoxBuilder(
    computed: rootNode.computed,
    node: rootNode
  )
  ctx.iroot = parent
  for i in 1 ..< ctx.inlineStack.len:
    let node = ctx.inlineStack[i]
    let nbox = InlineBoxBuilder(computed: node.computed, node: node)
    parent.children.add(nbox)
    parent = nbox
  return parent

proc generateFromElem(ctx: var InnerBlockContext; styledNode: StyledNode) =
  let box = ctx.blockgroup.parent
  case styledNode.computed{"display"}
  of DisplayBlock, DisplayFlowRoot:
    ctx.iflush()
    ctx.flush()
    let childbox = ctx.generateBlockBox(styledNode)
    box.children.add(childbox)
  of DisplayFlex:
    ctx.iflush()
    ctx.flush()
    let childbox = ctx.generateFlexBox(styledNode)
    box.children.add(childbox)
  of DisplayListItem:
    ctx.flush()
    inc ctx.listItemCounter
    let childbox = ListItemBoxBuilder(
      computed: styledNode.computed,
      marker: newMarkerBox(styledNode.computed, ctx.listItemCounter)
    )
    if childbox.computed{"list-style-position"} == ListStylePositionInside:
      childbox.content = ctx.generateBlockBox(styledNode, some(childbox.marker))
      childbox.marker = nil
    else:
      childbox.content = ctx.generateBlockBox(styledNode)
    childbox.content.computed = childbox.content.computed.copyProperties()
    childbox.content.computed{"display"} = DisplayBlock
    box.children.add(childbox)
  of DisplayInline:
    ctx.generateInlineBoxes(styledNode)
  of DisplayInlineBlock, DisplayInlineTable, DisplayInlineFlex:
    # create a new inline box that we can safely put our inline block into
    ctx.iflush()
    let computed = styledNode.computed.inheritProperties()
    ctx.ibox = InlineBoxBuilder(computed: computed, node: styledNode)
    if ctx.inlineStack.len > 0:
      let iparent = ctx.reconstructInlineParents()
      iparent.children.add(ctx.ibox)
      ctx.iroot = iparent
    else:
      ctx.iroot = ctx.ibox
    var childbox: BoxBuilder
    if styledNode.computed{"display"} == DisplayInlineBlock:
      childbox = ctx.generateBlockBox(styledNode)
    elif styledNode.computed{"display"} == DisplayInlineTable:
      childbox = styledNode.generateTableBox(ctx.lctx, ctx)
    else:
      assert styledNode.computed{"display"} == DisplayInlineFlex
      childbox = ctx.generateFlexBox(styledNode)
    ctx.ibox.children.add(childbox)
    ctx.iflush()
  of DisplayTable:
    ctx.flush()
    let childbox = styledNode.generateTableBox(ctx.lctx, ctx)
    box.children.add(childbox)
  of DisplayTableRow:
    ctx.bflush()
    ctx.flushTableRow()
    let childbox = styledNode.generateTableRowBox(ctx.lctx, ctx)
    if box.computed{"display"} in ProperTableRowParent:
      box.children.add(childbox)
    else:
      if ctx.anonTable == nil:
        var wrappervals = box.computed.inheritProperties()
        #TODO make this an inline-table if we're in an inline context
        wrappervals{"display"} = DisplayTable
        ctx.anonTable = TableBoxBuilder(computed: wrappervals)
      ctx.anonTable.children.add(childbox)
  of DisplayTableRowGroup, DisplayTableHeaderGroup, DisplayTableFooterGroup:
    ctx.bflush()
    ctx.flushTableRow()
    let childbox = styledNode.generateTableRowGroupBox(ctx.lctx, ctx)
    if box.computed{"display"} in {DisplayTable, DisplayInlineTable}:
      box.children.add(childbox)
    else:
      if ctx.anonTable == nil:
        var wrappervals = box.computed.inheritProperties()
        #TODO make this an inline-table if we're in an inline context
        wrappervals{"display"} = DisplayTable
        ctx.anonTable = TableBoxBuilder(computed: wrappervals)
      ctx.anonTable.children.add(childbox)
  of DisplayTableCell:
    ctx.bflush()
    let childbox = styledNode.generateTableCellBox(ctx.lctx, ctx)
    if box.computed{"display"} == DisplayTableRow:
      box.children.add(childbox)
    else:
      if ctx.anonRow == nil:
        var wrappervals = box.computed.inheritProperties()
        wrappervals{"display"} = DisplayTableRow
        ctx.anonRow = TableRowBoxBuilder(computed: wrappervals)
      ctx.anonRow.children.add(childbox)
  of DisplayTableCaption:
    ctx.bflush()
    ctx.flushTableRow()
    let childbox = styledNode.generateTableCaptionBox(ctx.lctx, ctx)
    if box.computed{"display"} in {DisplayTable, DisplayInlineTable}:
      box.children.add(childbox)
    else:
      if ctx.anonTable == nil:
        var wrappervals = box.computed.inheritProperties()
        #TODO make this an inline-table if we're in an inline context
        wrappervals{"display"} = DisplayTable
        ctx.anonTable = TableBoxBuilder(computed: wrappervals)
      ctx.anonTable.children.add(childbox)
  of DisplayTableColumn:
    discard #TODO
  of DisplayTableColumnGroup:
    discard #TODO
  of DisplayNone: discard

proc generateAnonymousInlineText(ctx: var InnerBlockContext; text: string;
    styledNode: StyledNode; bmp: Bitmap = nil) =
  if ctx.iroot == nil:
    let computed = styledNode.computed.inheritProperties()
    ctx.ibox = InlineBoxBuilder(computed: computed, node: styledNode, bmp: bmp)
    if ctx.inlineStack.len > 0:
      let iparent = ctx.reconstructInlineParents()
      iparent.children.add(ctx.ibox)
      ctx.iroot = iparent
    else:
      ctx.iroot = ctx.ibox
  ctx.ibox.text.add(text)

proc generateReplacement(ctx: var InnerBlockContext;
    child, parent: StyledNode) =
  case child.content.t
  of ContentOpenQuote:
    let quotes = parent.computed{"quotes"}
    var text: string
    if quotes.qs.len > 0:
      text = quotes.qs[min(ctx.quoteLevel, quotes.qs.high)].s
    elif quotes.auto:
      text = quoteStart(ctx.quoteLevel)
    else: return
    ctx.generateAnonymousInlineText(text, parent)
    inc ctx.quoteLevel
  of ContentCloseQuote:
    if ctx.quoteLevel > 0: dec ctx.quoteLevel
    let quotes = parent.computed{"quotes"}
    var text: string
    if quotes.qs.len > 0:
      text = quotes.qs[min(ctx.quoteLevel, quotes.qs.high)].e
    elif quotes.auto:
      text = quoteEnd(ctx.quoteLevel)
    else: return
    ctx.generateAnonymousInlineText(text, parent)
  of ContentNoOpenQuote:
    inc ctx.quoteLevel
  of ContentNoCloseQuote:
    if ctx.quoteLevel > 0: dec ctx.quoteLevel
  of ContentString:
    #TODO canGenerateAnonymousInline?
    ctx.generateAnonymousInlineText(child.content.s, parent)
  of ContentImage:
    #TODO idk
    ctx.generateAnonymousInlineText("[img]", parent, child.content.bmp)
  of ContentVideo:
    ctx.generateAnonymousInlineText("[video]", parent)
  of ContentAudio:
    ctx.generateAnonymousInlineText("[audio]", parent)
  of ContentNewline:
    ctx.iflush()
    #TODO ??
    # this used to set ibox (before we had iroot), now I'm not sure if we
    # should reconstruct here first
    ctx.iroot = InlineBoxBuilder(computed: parent.computed.inheritProperties())
    ctx.iroot.newline = true
    ctx.iflush()

proc generateInlineBoxes(ctx: var InnerBlockContext; styledNode: StyledNode) =
  ctx.iflush()
  ctx.inlineStack.add(styledNode)
  var lbox = ctx.reconstructInlineParents()
  lbox.splitType.incl(stSplitStart)
  ctx.ibox = lbox
  for child in styledNode.children:
    case child.t
    of stElement:
      ctx.generateFromElem(child)
    of stText:
      if ctx.ibox != lbox:
        ctx.iflush()
        lbox = ctx.reconstructInlineParents()
        ctx.ibox = lbox
      lbox.text.add(child.text)
    of stReplacement:
      ctx.generateReplacement(child, styledNode)
  if ctx.ibox != lbox:
    ctx.iflush()
    lbox = ctx.reconstructInlineParents()
    ctx.ibox = lbox
  lbox.splitType.incl(stSplitEnd)
  ctx.inlineStack.setLen(ctx.inlineStack.len - 1)
  ctx.iflush()

proc newInnerBlockContext(styledNode: StyledNode; box: BlockBoxBuilder;
    lctx: LayoutState; parent: ptr InnerBlockContext): InnerBlockContext =
  var ctx = InnerBlockContext(
    styledNode: styledNode,
    blockgroup: newBlockGroup(box),
    lctx: lctx,
    parent: parent
  )
  if parent != nil:
    ctx.listItemCounter = parent[].listItemCounter
    ctx.quoteLevel = parent[].quoteLevel
  for reset in styledNode.computed{"counter-reset"}:
    if reset.name == "list-item":
      ctx.listItemCounter = reset.num
      ctx.listItemReset = true
  return ctx

proc generateInnerBlockBox(ctx: var InnerBlockContext) =
  let box = ctx.blockgroup.parent
  assert box.computed{"display"} != DisplayInline
  for child in ctx.styledNode.children:
    case child.t
    of stElement:
      ctx.iflush()
      ctx.generateFromElem(child)
    of stText:
      if canGenerateAnonymousInline(ctx.blockgroup, box.computed, child.text):
        ctx.generateAnonymousInlineText(child.text, ctx.styledNode)
    of stReplacement:
      ctx.generateReplacement(child, ctx.styledNode)
  ctx.iflush()

proc generateBlockBox(styledNode: StyledNode; lctx: LayoutState;
    marker = none(MarkerBoxBuilder); parent: ptr InnerBlockContext = nil):
    BlockBoxBuilder =
  let box = BlockBoxBuilder(computed: styledNode.computed)
  box.node = styledNode
  var ctx = newInnerBlockContext(styledNode, box, lctx, parent)
  if marker.isSome:
    ctx.ibox = marker.get
    ctx.iflush()
  ctx.generateInnerBlockBox()
  # Flush anonymous tables here, to avoid setting inline layout with tables.
  ctx.flushTableRow()
  ctx.flushTable()
  # (flush here, because why not)
  ctx.flushInherit()
  # Avoid unnecessary anonymous block boxes. This also helps set our layout to
  # inline even if no inner anonymous block was generated.
  if box.children.len == 0:
    box.children = ctx.blockgroup.boxes
    box.inlinelayout = true
    ctx.blockgroup.boxes.setLen(0)
  ctx.blockgroup.flush()
  return box

proc generateFlexBox(styledNode: StyledNode; lctx: LayoutState;
    parent: ptr InnerBlockContext = nil): BlockBoxBuilder =
  let box = BlockBoxBuilder(computed: styledNode.computed, node: styledNode)
  var ctx = newInnerBlockContext(styledNode, box, lctx, parent)
  assert box.computed{"display"} != DisplayInline
  for child in ctx.styledNode.children:
    case child.t
    of stElement:
      ctx.iflush()
      let display = child.computed{"display"}.blockify()
      if display != child.computed{"display"}:
        #TODO this is a hack.
        # it exists because passing down a different `computed' would need
        # changes in way too many procedures, which I am not ready to make yet.
        let newChild = StyledNode()
        newChild[] = child[]
        newChild.computed = child.computed.copyProperties()
        newChild.computed{"display"} = display
        ctx.generateFromElem(newChild)
      else:
        ctx.generateFromElem(child)
    of stText:
      if ctx.blockgroup.canGenerateAnonymousInline(box.computed, child.text):
        ctx.generateAnonymousInlineText(child.text, ctx.styledNode)
    of stReplacement:
      ctx.generateReplacement(child, ctx.styledNode)
  ctx.iflush()
  # Flush anonymous tables here, to avoid setting inline layout with tables.
  ctx.flushTableRow()
  ctx.flushTable()
  # (flush here, because why not)
  ctx.flushInherit()
  ctx.blockgroup.flush()
  assert not box.inlinelayout
  return box

proc generateTableCellBox(styledNode: StyledNode; lctx: LayoutState;
    parent: var InnerBlockContext): TableCellBoxBuilder =
  let box = TableCellBoxBuilder(computed: styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, lctx, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  return box

proc generateTableRowChildWrappers(box: TableRowBoxBuilder) =
  var newchildren = newSeqOfCap[BoxBuilder](box.children.len)
  var wrappervals = box.computed.inheritProperties()
  wrappervals{"display"} = DisplayTableCell
  for child in box.children:
    if child.computed{"display"} == DisplayTableCell:
      newchildren.add(child)
    else:
      let wrapper = TableCellBoxBuilder(computed: wrappervals)
      wrapper.children.add(child)
      newchildren.add(wrapper)
  box.children = newchildren

proc generateTableRowBox(styledNode: StyledNode; lctx: LayoutState;
    parent: var InnerBlockContext): TableRowBoxBuilder =
  let box = TableRowBoxBuilder(computed: styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, lctx, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  box.generateTableRowChildWrappers()
  return box

proc generateTableRowGroupChildWrappers(box: TableRowGroupBoxBuilder) =
  var newchildren = newSeqOfCap[BoxBuilder](box.children.len)
  var wrappervals = box.computed.inheritProperties()
  wrappervals{"display"} = DisplayTableRow
  for child in box.children:
    if child.computed{"display"} == DisplayTableRow:
      newchildren.add(child)
    else:
      let wrapper = TableRowBoxBuilder(computed: wrappervals)
      wrapper.children.add(child)
      wrapper.generateTableRowChildWrappers()
      newchildren.add(wrapper)
  box.children = newchildren

proc generateTableRowGroupBox(styledNode: StyledNode; lctx: LayoutState;
    parent: var InnerBlockContext): TableRowGroupBoxBuilder =
  let box = TableRowGroupBoxBuilder(computed: styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, lctx, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  box.generateTableRowGroupChildWrappers()
  return box

proc generateTableCaptionBox(styledNode: StyledNode; lctx: LayoutState;
    parent: var InnerBlockContext): TableCaptionBoxBuilder =
  let box = TableCaptionBoxBuilder(computed: styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, lctx, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  return box

proc generateTableChildWrappers(box: TableBoxBuilder) =
  var newchildren = newSeqOfCap[BoxBuilder](box.children.len)
  var wrappervals = box.computed.inheritProperties()
  wrappervals{"display"} = DisplayTableRow
  for child in box.children:
    if child.computed{"display"} in ProperTableChild:
      newchildren.add(child)
    else:
      let wrapper = TableRowBoxBuilder(computed: wrappervals)
      wrapper.children.add(child)
      wrapper.generateTableRowChildWrappers()
      newchildren.add(wrapper)
  box.children = newchildren

proc generateTableBox(styledNode: StyledNode; lctx: LayoutState;
    parent: var InnerBlockContext): TableBoxBuilder =
  let box = TableBoxBuilder(computed: styledNode.computed, node: styledNode)
  var ctx = newInnerBlockContext(styledNode, box, lctx, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  box.generateTableChildWrappers()
  return box

proc layout*(root: StyledNode; attrsp: ptr WindowAttributes): BlockBox =
  let space = availableSpace(
    w = stretch(attrsp[].width_px),
    h = stretch(attrsp[].height_px)
  )
  let lctx = LayoutState(
    attrsp: attrsp,
    positioned: @[space],
    myRootProperties: rootProperties()
  )
  let builder = root.generateBlockBox(lctx)
  var marginBottomOut: LayoutUnit
  return lctx.layoutRootBlock(builder, space, offset(x = 0, y = 0),
    marginBottomOut)

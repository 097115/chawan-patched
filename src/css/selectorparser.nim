import strutils
import unicode

import css/cssparser
import html/tags

type
  SelectorType* = enum
    TYPE_SELECTOR, ID_SELECTOR, ATTR_SELECTOR, CLASS_SELECTOR,
    UNIVERSAL_SELECTOR, PSEUDO_SELECTOR, PSELEM_SELECTOR, FUNC_SELECTOR,
    COMBINATOR_SELECTOR

  QueryMode = enum
    QUERY_TYPE, QUERY_CLASS, QUERY_ATTR, QUERY_DELIM, QUERY_VALUE,
    QUERY_PSEUDO, QUERY_PSELEM, QUERY_DESC_COMBINATOR, QUERY_CHILD_COMBINATOR,
    QUERY_NEXT_SIBLING_COMBINATOR, QUERY_SUBSEQ_SIBLING_COMBINATOR

  PseudoElem* = enum
    PSEUDO_NONE, PSEUDO_BEFORE, PSEUDO_AFTER,
    # internal
    PSEUDO_INPUT_TEXT

  PseudoClass* = enum
    PSEUDO_FIRST_CHILD, PSEUDO_LAST_CHILD, PSEUDO_ONLY_CHILD, PSEUDO_HOVER,
    PSEUDO_ROOT, PSEUDO_NTH_CHILD, PSEUDO_CHECKED, PSEUDO_FOCUS

  CombinatorType* = enum
    DESCENDANT_COMBINATOR, CHILD_COMBINATOR, NEXT_SIBLING_COMBINATOR,
    SUBSEQ_SIBLING_COMBINATOR

  FunctionType* = enum
    FUNCTION_IS, FUNCTION_NOT, FUNCTION_WHERE

  SelectorParser = object
    selectors: seq[SelectorList]
    query: QueryMode
    combinator: Selector

  #TODO combinators
  Selector* = ref object of RootObj
    case t*: SelectorType
    of TYPE_SELECTOR:
      tag*: TagType
    of ID_SELECTOR:
      id*: string
    of ATTR_SELECTOR:
      attr*: string
      value*: string
      rel*: char
    of CLASS_SELECTOR:
      class*: string
    of UNIVERSAL_SELECTOR: #TODO namespaces?
      discard
    of PSEUDO_SELECTOR:
      pseudo*: PseudoClass
      pseudonum*: float64
    of PSELEM_SELECTOR:
      elem*: PseudoElem
    of FUNC_SELECTOR:
      ftype*: FunctionType
      fsels*: seq[SelectorList]
    of COMBINATOR_SELECTOR:
      ct*: CombinatorType
      csels*: seq[SelectorList]

  SelectorList* = ref object
    sels*: seq[Selector]
    pseudo*: PseudoElem

# For debugging
proc tostr(ftype: enum): string =
  return ($ftype).split('_')[1..^1].join("-").tolower()

proc `$`*(sellist: SelectorList): string

proc `$`*(sel: Selector): string =
  case sel.t
  of TYPE_SELECTOR:
    return tagName(sel.tag)
  of ID_SELECTOR:
    return '#' & sel.id
  of ATTR_SELECTOR:
    return '[' & sel.attr & sel.rel & sel.value & ']'
  of CLASS_SELECTOR:
    return '.' & sel.class
  of UNIVERSAL_SELECTOR:
    return "*"
  of PSEUDO_SELECTOR:
    return ':' & sel.pseudo.tostr()
  of PSELEM_SELECTOR:
    return "::" & sel.elem.tostr()
  of FUNC_SELECTOR:
    result = ':' & sel.ftype.tostr() & '('
    for fsel in sel.fsels:
      result &= $fsel
      if fsel != sel.fsels[^1]:
        result &= ','
    result &= ')'
  of COMBINATOR_SELECTOR:
    var delim: char
    case sel.ct
    of DESCENDANT_COMBINATOR: delim = ' '
    of CHILD_COMBINATOR: delim = '>'
    of NEXT_SIBLING_COMBINATOR: delim = '+'
    of SUBSEQ_SIBLING_COMBINATOR: delim = '~'
    for slist in sel.csels:
      result &= $slist
      if slist != sel.csels[^1]:
        result &= delim

proc `$`*(sellist: SelectorList): string =
  for sel in sellist.sels:
    result &= $sel
  case sellist.pseudo
  of PSEUDO_BEFORE:
    result &= "::before"
  of PSEUDO_AFTER:
    result &= "::after"
  else: discard

proc add(sellist: SelectorList, sel: Selector) = sellist.sels.add(sel)
proc add(sellist: SelectorList, sels: SelectorList) = sellist.sels.add(sels.sels)
proc `[]`*(sellist: SelectorList, i: int): Selector = sellist.sels[i]
proc len*(sellist: SelectorList): int = sellist.sels.len

func getSpecificity*(sels: SelectorList): int

func getSpecificity(sel: Selector): int =
  case sel.t
  of ID_SELECTOR:
    result += 1000000
  of CLASS_SELECTOR, ATTR_SELECTOR, PSEUDO_SELECTOR:
    result += 1000
  of TYPE_SELECTOR, PSELEM_SELECTOR:
    result += 1
  of FUNC_SELECTOR:
    case sel.ftype
    of FUNCTION_IS, FUNCTION_NOT:
      var best = 0
      for child in sel.fsels:
        let s = getSpecificity(child)
        if s > best:
          best = s
      result += best
    else: discard
  of UNIVERSAL_SELECTOR:
    discard
  of COMBINATOR_SELECTOR:
    for child in sel.csels:
      result += getSpecificity(child)

func getSpecificity*(sels: SelectorList): int =
  for sel in sels.sels:
    result += getSpecificity(sel)

func optimizeSelectorList*(selectors: SelectorList): SelectorList =
  new(result)
  #pass 1: check for invalid sequences
  var i = 1
  while i < selectors.len:
    let sel = selectors[i]
    if sel.t == TYPE_SELECTOR or sel.t == UNIVERSAL_SELECTOR:
      return SelectorList()
    inc i

  #pass 2: move selectors in combination
  if selectors.len > 1:
    var i = 0
    var slow = SelectorList()
    if selectors[0].t == UNIVERSAL_SELECTOR:
      inc i

    while i < selectors.len:
      if selectors[i].t in {ATTR_SELECTOR, PSEUDO_SELECTOR, PSELEM_SELECTOR}:
        slow.add(selectors[i])
      else:
        result.add(selectors[i])
      inc i

    result.add(slow)
  else:
    result.add(selectors[0])

proc addSelector(state: var SelectorParser, sel: Selector) =
  if state.combinator != nil:
    if sel.t == PSELEM_SELECTOR:
      state.combinator.csels[^1].pseudo = sel.elem
    state.combinator.csels[^1].add(sel)
  else:
    if sel.t == PSELEM_SELECTOR:
      state.selectors[^1].pseudo = sel.elem
    state.selectors[^1].add(sel)

proc getLastSel(state: SelectorParser): Selector =
  if state.combinator != nil:
    return state.combinator.csels[^1].sels[^1]
  else:
    return state.selectors[^1].sels[^1]

proc addSelectorList(state: var SelectorParser) =
  if state.combinator != nil:
    state.selectors[^1].add(state.combinator)
    state.combinator = nil
  state.selectors.add(SelectorList())

func getSelectorLists(state: var SelectorParser): seq[SelectorList] =
  result = state.selectors
  if state.combinator != nil:
    result[^1].add(state.combinator)

proc parseSelectorCombinator(state: var SelectorParser, ct: CombinatorType, csstoken: CSSToken) =
  if csstoken.tokenType in {CSS_IDENT_TOKEN, CSS_HASH_TOKEN,
                            CSS_COLON_TOKEN}:
    if state.combinator != nil and state.combinator.ct != ct:
      let nc = Selector(t: COMBINATOR_SELECTOR, ct: ct)
      nc.csels.add(SelectorList())
      nc.csels[^1].add(state.combinator)
      state.combinator = nc

    if state.combinator == nil:
      state.combinator = Selector(t: COMBINATOR_SELECTOR, ct: ct)

    state.combinator.csels.add(state.selectors[^1])
    if state.combinator.csels[^1].len > 0:
      state.combinator.csels.add(SelectorList())
    state.selectors[^1] = SelectorList()
    state.query = QUERY_TYPE

proc parseSelectorToken(state: var SelectorParser, csstoken: CSSToken) =
  case state.query
  of QUERY_DESC_COMBINATOR:
    state.parseSelectorCombinator(DESCENDANT_COMBINATOR, csstoken)
  of QUERY_CHILD_COMBINATOR:
    if csstoken.tokenType == CSS_WHITESPACE_TOKEN:
      return
    state.parseSelectorCombinator(CHILD_COMBINATOR, csstoken)
  of QUERY_NEXT_SIBLING_COMBINATOR:
    if csstoken.tokenType == CSS_WHITESPACE_TOKEN:
      return
    state.parseSelectorCombinator(NEXT_SIBLING_COMBINATOR, csstoken)
  of QUERY_SUBSEQ_SIBLING_COMBINATOR:
    if csstoken.tokenType == CSS_WHITESPACE_TOKEN:
      return
    state.parseSelectorCombinator(SUBSEQ_SIBLING_COMBINATOR, csstoken)
  else: discard

  case csstoken.tokenType
  of CSS_IDENT_TOKEN:
    case state.query
    of QUERY_CLASS:
      state.addSelector(Selector(t: CLASS_SELECTOR, class: csstoken.value))
    of QUERY_TYPE:
      state.addSelector(Selector(t: TYPE_SELECTOR, tag: tagType(csstoken.value)))
    of QUERY_PSEUDO:
      case csstoken.value
      of "before":
        state.addSelector(Selector(t: PSELEM_SELECTOR, elem: PSEUDO_BEFORE))
      of "after":
        state.addSelector(Selector(t: PSELEM_SELECTOR, elem: PSEUDO_AFTER))
      of "first-child":
        state.addSelector(Selector(t: PSEUDO_SELECTOR, pseudo: PSEUDO_FIRST_CHILD))
      of "last-child":
        state.addSelector(Selector(t: PSEUDO_SELECTOR, pseudo: PSEUDO_LAST_CHILD))
      of "only-child":
        state.addSelector(Selector(t: PSEUDO_SELECTOR, pseudo: PSEUDO_ONLY_CHILD))
      of "hover":
        state.addSelector(Selector(t: PSEUDO_SELECTOR, pseudo: PSEUDO_HOVER))
      of "root":
        state.addSelector(Selector(t: PSEUDO_SELECTOR, pseudo: PSEUDO_ROOT))
      of "checked":
        state.addSelector(Selector(t: PSEUDO_SELECTOR, pseudo: PSEUDO_CHECKED))
      of "focus":
        state.addSelector(Selector(t: PSEUDO_SELECTOR, pseudo: PSEUDO_FOCUS))
    of QUERY_PSELEM:
      case csstoken.value
      of "before":
        state.addSelector(Selector(t: PSELEM_SELECTOR, elem: PSEUDO_BEFORE))
      of "after":
        state.addSelector(Selector(t: PSELEM_SELECTOR, elem: PSEUDO_AFTER))
      else: discard
    else: discard
    state.query = QUERY_TYPE
  of CSS_DELIM_TOKEN:
    case csstoken.rvalue
    of Rune('.'):
      state.query = QUERY_CLASS
    of Rune('>'):
      if state.selectors[^1].len > 0 or state.combinator != nil:
        state.query = QUERY_CHILD_COMBINATOR
    of Rune('+'):
      if state.selectors[^1].len > 0 or state.combinator != nil:
        state.query = QUERY_NEXT_SIBLING_COMBINATOR
    of Rune('~'):
      if state.selectors[^1].len > 0 or state.combinator != nil:
        state.query = QUERY_SUBSEQ_SIBLING_COMBINATOR
    of Rune('*'):
      state.addSelector(Selector(t: UNIVERSAL_SELECTOR))
    else: discard
  of CSS_HASH_TOKEN:
    state.addSelector(Selector(t: ID_SELECTOR, id: csstoken.value))
  of CSS_COMMA_TOKEN:
    if state.selectors[^1].len > 0:
      state.addSelectorList()
  of CSS_WHITESPACE_TOKEN:
    if state.selectors[^1].len > 0 or state.combinator != nil:
      state.query = QUERY_DESC_COMBINATOR
  of CSS_COLON_TOKEN:
    if state.query == QUERY_PSEUDO:
      state.query = QUERY_PSELEM
    else:
      state.query = QUERY_PSEUDO
  else: discard

proc parseSelectorSimpleBlock(state: var SelectorParser, cssblock: CSSSimpleBlock) =
  case cssblock.token.tokenType
  of CSS_LBRACKET_TOKEN:
    state.query = QUERY_ATTR
    for cval in cssblock.value:
      if cval of CSSToken:
        let csstoken = (CSSToken)cval
        case csstoken.tokenType
        of CSS_IDENT_TOKEN:
          case state.query
          of QUERY_ATTR:
            state.query = QUERY_DELIM
            state.addSelector(Selector(t: ATTR_SELECTOR, attr: csstoken.value, rel: ' '))
          of QUERY_VALUE:
            state.getLastSel().value = csstoken.value
            break
          else: discard
        of CSS_STRING_TOKEN:
          case state.query
          of QUERY_VALUE:
            state.getLastSel().value = csstoken.value
            break
          else: discard
        of CSS_DELIM_TOKEN:
          case csstoken.rvalue
          of Rune('~'), Rune('|'), Rune('^'), Rune('$'), Rune('*'):
            if state.query == QUERY_DELIM:
              state.getLastSel().rel = char(csstoken.rvalue)
          of Rune('='):
            if state.query == QUERY_DELIM:
              if state.getLastSel().rel == ' ':
                state.getLastSel().rel = '='
              state.query = QUERY_VALUE
          else: discard
        else: discard
    state.query = QUERY_TYPE
  else: discard

proc parseNthChild(state: var SelectorParser, cssfunction: CSSFunction) =
  if cssfunction.value.len != 1 or not (cssfunction.value[0] of CSSToken):
    return
  if CSSToken(cssfunction.value[0]).tokenType != CSS_NUMBER_TOKEN:
    return
  let num = CSSToken(cssfunction.value[0]).nvalue
  if num == float64(int64(num)):
    state.addSelector(Selector(t: PSEUDO_SELECTOR, pseudo: PSEUDO_NTH_CHILD, pseudonum: num))
  state.query = QUERY_TYPE

proc parseSelectorFunction(state: var SelectorParser, cssfunction: CSSFunction) =
  if state.query != QUERY_PSEUDO:
    return
  let ftype = case cssfunction.name
  of "not": FUNCTION_NOT
  of "is": FUNCTION_IS
  of "where": FUNCTION_WHERE
  of "nth-child":
    state.parseNthChild(cssfunction)
    return
  else: return
  state.query = QUERY_TYPE
  var fun = Selector(t: FUNC_SELECTOR, ftype: ftype)
  state.addSelector(fun)

  let osels = state.selectors
  let ocomb = state.combinator
  state.combinator = nil
  state.selectors = newSeq[SelectorList]()
  state.addSelectorList()
  for cval in cssfunction.value:
    if cval of CSSToken:
      state.parseSelectorToken(CSSToken(cval))
    elif cval of CSSSimpleBlock:
      state.parseSelectorSimpleBlock(CSSSimpleBlock(cval))
    elif cval of CSSFunction:
      state.parseSelectorFunction(CSSFunction(cval))
  fun.fsels = state.getSelectorLists()
  state.selectors = osels
  state.combinator = ocomb

func parseSelectors*(cvals: seq[CSSComponentValue]): seq[SelectorList] =
  var state = SelectorParser()
  state.addSelectorList()
  for cval in cvals:
    if cval of CSSToken:
      state.parseSelectorToken(CSSToken(cval))
    elif cval of CSSSimpleBlock:
      state.parseSelectorSimpleBlock(CSSSimpleBlock(cval))
    elif cval of CSSFunction:
      state.parseSelectorFunction(CSSFunction(cval))
  if state.combinator != nil:
    state.selectors[^1].add(state.combinator)
    state.combinator = nil
  return state.selectors

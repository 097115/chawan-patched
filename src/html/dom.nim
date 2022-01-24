import tables
import options
import streams
import strutils

import css/values
import css/sheet
import html/tags
import types/url

type
  EventTarget* = ref EventTargetObj
  EventTargetObj = object of RootObj

  Node* = ref NodeObj
  NodeObj = object of EventTargetObj
    nodeType*: NodeType
    childNodes*: seq[Node]
    children*: seq[Element]
    isConnected*: bool
    nextSibling*: Node
    previousSibling*: Node
    parentNode*: Node
    parentElement*: Element
    ownerDocument*: Document
    uid*: int # Unique id

  Attr* = ref AttrObj
  AttrObj = object of NodeObj
    namespaceURI*: string
    prefix*: string
    localName*: string
    name*: string
    value*: string
    ownerElement*: Element

  Document* = ref DocumentObj
  DocumentObj = object of NodeObj
    location*: Url
    type_elements*: array[TagType, seq[Element]]
    id_elements*: Table[string, seq[Element]]
    class_elements*: Table[string, seq[Element]]
    all_elements*: seq[Element]
    head*: HTMLElement
    body*: HTMLElement
    root*: Element

  CharacterData* = ref CharacterDataObj
  CharacterDataObj = object of NodeObj
    data*: string
    length*: int

  Text* = ref TextObj
  TextObj = object of CharacterDataObj
    wholeText*: string

  Comment* = ref CommentObj
  CommentObj = object of CharacterDataObj

  Element* = ref ElementObj
  ElementObj = object of NodeObj
    namespaceURI*: string
    prefix*: string
    localName*: string
    tagName*: string
    tagType*: TagType

    sheets*: seq[CSSStylesheet]
    id*: string
    classList*: seq[string]
    attributes*: Table[string, string]
    css*: CSSSpecifiedValues
    pseudo*: array[PSEUDO_BEFORE..PSEUDO_AFTER, CSSSpecifiedValues]
    hover*: bool
    cssapplied*: bool
    rendered*: bool

  HTMLElement* = ref object of ElementObj

  HTMLInputElement* = ref object of HTMLElement
    itype*: InputType
    autofocus*: bool
    required*: bool
    value*: string
    size*: int

  HTMLAnchorElement* = ref object of HTMLElement
    href*: string

  HTMLSelectElement* = ref object of HTMLElement
    name*: string
    value*: string
    valueSet*: bool

  HTMLSpanElement* = ref object of HTMLElement

  HTMLOptionElement* = ref object of HTMLElement
    value*: string
  
  HTMLHeadingElement* = ref object of HTMLElement
    rank*: uint16

  HTMLBRElement* = ref object of HTMLElement

  HTMLMenuElement* = ref object of HTMLElement
    ordinalcounter*: int

  HTMLUListElement* = ref object of HTMLElement
    ordinalcounter*: int

  HTMLOListElement* = ref object of HTMLElement
    start*: Option[int]
    ordinalcounter*: int

  HTMLLIElement* = ref object of HTMLElement
    value*: Option[int]
    ordinalvalue*: int

  HTMLStyleElement* = ref object of HTMLElement
    sheet*: CSSStylesheet

  HTMLLinkElement* = ref object of HTMLElement
    href*: string
    rel*: string
    sheet*: CSSStylesheet
    s*: Stream

# For debugging
template `$`*(node: Node): string =
  case node.nodeType
  of ELEMENT_NODE:
    let element = Element(node)
    return "Element of " & $element.tagType & ", children: {\n" & $element.childNodes & "\n}"
  of TEXT_NODE:
    let text = Text(node)
    return "Text: " & text.data
  else:
    return "Node of " & $node.nodeType

iterator textNodes*(node: Node): Text {.inline.} =
  for node in node.childNodes:
    if node.nodeType == TEXT_NODE:
      yield Text(node)

# Returns the node's ancestors
iterator ancestors*(node: Node): Element {.inline.} =
  var element = node.parentElement
  while element != nil:
    yield element
    element = element.parentElement

# Returns the node itself and its ancestors
iterator branch*(node: Node): Node {.inline.} =
  var node = node
  while node != nil:
    yield node
    node = node.parentElement

# a == b or b in a's ancestors
func contains*(a, b: Node): bool =
  for node in a.branch:
    if node == b: return true
  return false

func branch*(node: Node): seq[Node] =
  for node in node.branch:
    result.add(node)

func firstChild(node: Node): Node =
  if node.childNodes.len == 0:
    return nil
  return node.childNodes[0]

func lastChild(node: Node): Node =
  if node.childNodes.len == 0:
    return nil
  return node.childNodes[^1]

func firstElementChild*(node: Node): Element =
  if node.children.len == 0:
    return nil
  return node.children[0]

func lastElementChild*(node: Node): Element =
  if node.children.len == 0:
    return nil
  return node.children[^1]

func previousElementSibling*(elem: Element): Element =
  var e = elem.previousSibling
  while e != nil:
    if e.nodeType == ELEMENT_NODE:
      return Element(e)
    e = e.previousSibling
  return nil

func nextElementSibling*(elem: Element): Element =
  var e = elem.nextSibling
  while e != nil:
    if e.nodeType == ELEMENT_NODE:
      return Element(e)
    e = e.nextSibling
  return nil

func isTextNode*(node: Node): bool =
  return node.nodeType == TEXT_NODE

func isElemNode*(node: Node): bool =
  return node.nodeType == ELEMENT_NODE

func isComment*(node: Node): bool =
  return node.nodeType == COMMENT_NODE

func isCData*(node: Node): bool =
  return node.nodeType == CDATA_SECTION_NODE

func isDocument*(node: Node): bool =
  return node.nodeType == DOCUMENT_NODE

func firstNode*(node: Node): bool =
  return node.parentElement != nil and node.parentElement.childNodes[0] == node

func lastNode*(node: Node): bool =
  return node.parentElement != nil and node.parentElement.childNodes[^1] == node

func toInputType*(str: string): InputType =
  case str
  of "button": INPUT_BUTTON
  of "checkbox": INPUT_CHECKBOX
  of "color": INPUT_COLOR
  of "date": INPUT_DATE
  of "datetime_local": INPUT_DATETIME_LOCAL
  of "email": INPUT_EMAIL
  of "file": INPUT_FILE
  of "hidden": INPUT_HIDDEN
  of "image": INPUT_IMAGE
  of "month": INPUT_MONTH
  of "number": INPUT_NUMBER
  of "password": INPUT_PASSWORD
  of "radio": INPUT_RADIO
  of "range": INPUT_RANGE
  of "reset": INPUT_RESET
  of "search": INPUT_SEARCH
  of "submit": INPUT_SUBMIT
  of "tel": INPUT_TEL
  of "text": INPUT_TEXT
  of "time": INPUT_TIME
  of "url": INPUT_URL
  of "week": INPUT_WEEK
  else: INPUT_UNKNOWN

func findAncestor*(node: Node, tagTypes: set[TagType]): Element =
  for element in node.ancestors:
    if element.tagType in tagTypes:
      return element
  return nil

func attr*(element: Element, s: string): string =
  return element.attributes.getOrDefault(s, "")

func attri*(element: Element, s: string): Option[int] =
  let a = element.attr(s)
  try:
    return some(parseInt(a))
  except ValueError:
    return none(int)

proc applyOrdinal*(elem: HTMLLIElement) =
  let val = elem.attri("value")
  if val.issome:
    elem.ordinalvalue = val.get
  else:
    let owner = elem.findAncestor({TAG_OL, TAG_UL, TAG_MENU})
    if owner == nil:
      elem.ordinalvalue = 1
    else:
      case owner.tagType
      of TAG_OL:
        let ol = HTMLOListElement(owner)
        elem.ordinalvalue = ol.ordinalcounter
        inc ol.ordinalcounter
      of TAG_UL:
        let ul = HTMLUListElement(owner)
        elem.ordinalvalue = ul.ordinalcounter
        inc ul.ordinalcounter
      of TAG_MENU:
        let menu = HTMLMenuElement(owner)
        elem.ordinalvalue = menu.ordinalcounter
        inc menu.ordinalcounter
      else: discard

func newText*(): Text =
  new(result)
  result.nodeType = TEXT_NODE

func newComment*(): Comment =
  new(result)
  result.nodeType = COMMENT_NODE

func newHtmlElement*(document: Document, tagType: TagType): HTMLElement =
  case tagType
  of TAG_INPUT:
    result = new(HTMLInputElement)
  of TAG_A:
    result = new(HTMLAnchorElement)
  of TAG_SELECT:
    result = new(HTMLSelectElement)
  of TAG_OPTION:
    result = new(HTMLOptionElement)
  of TAG_H1, TAG_H2, TAG_H3, TAG_H4, TAG_H5, TAG_H6:
    result = new(HTMLHeadingElement)
  of TAG_BR:
    result = new(HTMLBRElement)
  of TAG_SPAN:
    result = new(HTMLSpanElement)
  of TAG_OL:
    result = new(HTMLOListElement)
  of TAG_UL:
    result = new(HTMLUListElement)
    HTMLUListElement(result).ordinalcounter = 1
  of TAG_MENU:
    result = new(HTMLMenuElement)
    HTMLMenuElement(result).ordinalcounter = 1
  of TAG_LI:
    result = new(HTMLLIElement)
  of TAG_STYLE:
    result = new(HTMLStyleElement)
  of TAG_LINK:
    result = new(HTMLLinkElement)
  else:
    result = new(HTMLElement)

  result.nodeType = ELEMENT_NODE
  result.tagType = tagType
  result.css = rootProperties()
  result.uid = document.all_elements.len
  document.all_elements.add(result)

func newDocument*(): Document =
  new(result)
  result.root = result.newHtmlElement(TAG_HTML)
  result.head = result.newHtmlElement(TAG_HEAD)
  result.body = result.newHtmlElement(TAG_BODY)
  result.nodeType = DOCUMENT_NODE

func newAttr*(parent: Element, key, value: string): Attr =
  new(result)
  result.nodeType = ATTRIBUTE_NODE
  result.ownerElement = parent
  result.name = key
  result.value = value

func getElementById*(document: Document, id: string): Element =
  if id.len == 0 or id notin document.id_elements:
    return nil
  return document.id_elements[id][0]

func getElementsByTag*(document: Document, tag: TagType): seq[Element] =
  return document.type_elements[tag]

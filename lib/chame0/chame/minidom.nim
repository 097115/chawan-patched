## Minimal DOMBuilder example. Implements the absolute minimum required
## for htmlparser to work correctly.
##
## For an example of a complete implementation (with JS support and
## document.write), see Chawan's chadombuilder.
##
## Note: this only works with UTF-8 inputs. For a variant that can
## switch encodings when meta tags are encountered etc. see
## [chame/minidom_cs](minidom_cs.html).

import std/algorithm
import std/hashes
import std/options
import std/sets
import std/streams
import std/tables

import htmlparser
import tags

export tags

# Atom implementation
#TODO maybe we should use a better hash map.
const MAtomFactoryStrMapLength = 1024 # must be a power of 2
static:
  doAssert (MAtomFactoryStrMapLength and (MAtomFactoryStrMapLength - 1)) == 0

type
  MAtom* = distinct int

  MAtomFactory* = ref object of RootObj
    strMap: array[MAtomFactoryStrMapLength, seq[MAtom]]
    atomMap: seq[string]

# Mandatory Atom functions
func `==`*(a, b: MAtom): bool {.borrow.}
func hash*(atom: MAtom): Hash {.borrow.}

func strToAtom*(factory: MAtomFactory, s: string): MAtom

proc newMAtomFactory*(): MAtomFactory =
  const minCap = int(TagType.high) + 1
  let factory = MAtomFactory(
    atomMap: newSeqOfCap[string](minCap),
  )
  factory.atomMap.add("") # skip TAG_UNKNOWN
  for tagType in TagType(int(TAG_UNKNOWN) + 1) .. TagType.high:
    discard factory.strToAtom($tagType)
  return factory

func strToAtom*(factory: MAtomFactory, s: string): MAtom =
  let h = s.hash()
  let i = h and (factory.strMap.len - 1)
  for atom in factory.strMap[i]:
    if factory.atomMap[int(atom)] == s:
      # Found
      return atom
  # Not found
  let atom = MAtom(factory.atomMap.len)
  factory.atomMap.add(s)
  factory.strMap[i].add(atom)
  return atom

func tagTypeToAtom*(factory: MAtomFactory, tagType: TagType): MAtom =
  assert tagType != TAG_UNKNOWN
  return MAtom(tagType)

func atomToStr*(factory: MAtomFactory, atom: MAtom): string =
  return factory.atomMap[int(atom)]

# Node types
type
  Attribute* = ParsedAttr[MAtom]

  Node* = ref object of RootObj
    childList*: seq[Node]
    parentNode* {.cursor.}: Node

  CharacterData* = ref object of Node
    data*: string

  Comment* = ref object of CharacterData

  Document* = ref object of Node
    factory*: MAtomFactory

  Text* = ref object of CharacterData

  DocumentType* = ref object of Node
    name*: string
    publicId*: string
    systemId*: string

  Element* = ref object of Node
    localName*: MAtom
    namespace*: Namespace
    attrs*: seq[Attribute]
    document*: Document

  DocumentFragment* = ref object of Node

  HTMLTemplateElement* = ref object of Element
    content*: DocumentFragment

type
  MiniDOMBuilder* = ref object of DOMBuilder[Node, MAtom]
    document*: Document
    factory*: MAtomFactory

type
  DOMBuilderImpl = MiniDOMBuilder
  AtomImpl = MAtom
  HandleImpl = Node

include htmlparseriface

func toTagType*(atom: MAtom): TagType {.inline.} =
  if int(atom) <= int(high(TagType)):
    return TagType(atom)
  return TAG_UNKNOWN

func tagType*(element: Element): TagType =
  return element.localName.toTagType()

func cmp*(a, b: MAtom): int {.inline.} =
  return cmp(int(a), int(b))

# We use this to validate input strings, since htmltokenizer/htmlparser does no
# input validation.
proc toValidUTF8(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    if int(s[i]) < 0x80:
      result &= s[i]
      inc i
    elif int(s[i]) shr 5 == 0x6:
      if i + 1 < s.len and int(s[i + 1]) shr 6 == 2:
        result &= s[i]
        result &= s[i + 1]
      else:
        result &= "\uFFFD"
      i += 2
    elif int(s[i]) shr 4 == 0xE:
      if i + 2 < s.len and int(s[i + 1]) shr 6 == 2 and
          int(s[i + 2]) shr 6 == 2:
        result &= s[i]
        result &= s[i + 1]
        result &= s[i + 2]
      else:
        result &= "\uFFFD"
      i += 3
    elif int(s[i]) shr 3 == 0x1E:
      if i + 3 < s.len and int(s[i + 1]) shr 6 == 2 and
          int(s[i + 2]) shr 6 == 2 and int(s[i + 3]) shr 6 == 2:
        result &= s[i]
        result &= s[i + 1]
        result &= s[i + 2]
        result &= s[i + 3]
      else:
        result &= "\uFFFD"
      i += 4
    else:
      result &= "\uFFFD"
      inc i

proc localNameStr*(element: Element): string =
  return element.document.factory.atomToStr(element.localName)

iterator attrsStr*(element: Element): tuple[name, value: string] =
  let factory = element.document.factory
  for attr in element.attrs:
    var name = ""
    if attr.prefix != NO_PREFIX:
      name &= $attr.prefix & ':'
    name &= factory.atomToStr(attr.name)
    yield (name, attr.value)

# htmlparseriface implementation
proc strToAtomImpl(builder: MiniDOMBuilder, s: string): MAtom =
  return builder.factory.strToAtom(s)

proc tagTypeToAtomImpl(builder: MiniDOMBuilder, tagType: TagType): MAtom =
  return builder.factory.tagTypeToAtom(tagType)

proc atomToTagTypeImpl(builder: MiniDOMBuilder, atom: MAtom): TagType =
  return atom.toTagType()

proc getDocumentImpl(builder: MiniDOMBuilder): Node =
  return builder.document

proc getParentNodeImpl(builder: MiniDOMBuilder, handle: Node): Option[Node] =
  return option(handle.parentNode)

proc createElement(document: Document, localName: MAtom, namespace: Namespace):
    Element =
  let element = if localName.toTagType() == TAG_TEMPLATE and
      namespace == Namespace.HTML:
    HTMLTemplateElement(
      content: DocumentFragment()
    )
  else:
    Element()
  element.localName = localName
  element.namespace = namespace
  element.document = document
  return element

proc createHTMLElementImpl(builder: MiniDOMBuilder): Node =
  let localName = builder.factory.tagTypeToAtom(TAG_HTML)
  return builder.document.createElement(localName, Namespace.HTML)

proc createElementForTokenImpl(builder: MiniDOMBuilder, localName: MAtom,
    namespace: Namespace, intendedParent: Node, htmlAttrs: Table[MAtom, string],
    xmlAttrs: seq[Attribute]): Node =
  let element = builder.document.createElement(localName, namespace)
  element.attrs = xmlAttrs
  for k, v in htmlAttrs:
    element.attrs.add((NO_PREFIX, NO_NAMESPACE, k, v.toValidUTF8()))
  element.attrs.sort(func(a, b: Attribute): int = cmp(a.name, b.name))
  return element

proc getLocalNameImpl(builder: MiniDOMBuilder, handle: Node): MAtom =
  return Element(handle).localName

proc getNamespaceImpl(builder: MiniDOMBuilder, handle: Node): Namespace =
  return Element(handle).namespace

proc getTemplateContentImpl(builder: MiniDOMBuilder, handle: Node): Node =
  return HTMLTemplateElement(handle).content

proc createCommentImpl(builder: MiniDOMBuilder, text: string): Node =
  return Comment(data: text.toValidUTF8())

proc createDocumentTypeImpl(builder: MiniDOMBuilder, name, publicId,
    systemId: string): Node =
  return DocumentType(
    name: name.toValidUTF8(),
    publicId: publicId.toValidUTF8(),
    systemId: systemId.toValidUTF8()
  )

func countElementChildren(node: Node): int =
  result = 0
  for child in node.childList:
    if child of Element:
      inc result

func hasTextChild(node: Node): bool =
  for child in node.childList:
    if child of Text:
      return true
  return false

func hasElementChild(node: Node): bool =
  for child in node.childList:
    if child of Element:
      return true
  return false

func hasDocumentTypeChild(node: Node): bool =
  for child in node.childList:
    if child of DocumentType:
      return true
  return false

func isHostIncludingInclusiveAncestor(a, b: Node): bool =
  var b = b
  while b != nil:
    if b == a:
      return true
    b = b.parentNode
  return false

func hasPreviousElementSibling(node: Node): bool =
  for n in node.parentNode.childList:
    if n == node:
      break
    if n of Element:
      return true
  return false

func hasNextDocumentTypeSibling(node: Node): bool =
  for i in countdown(node.parentNode.childList.len, 0):
    let n = node.parentNode.childList[i]
    if n == node:
      break
    if n of DocumentType:
      return true
  return false

func isValidParent(node: Node): bool =
  return node of Element or node of Document or node of DocumentFragment

func isValidChild(node: Node): bool =
  return node.isValidParent or node of DocumentType or node of CharacterData

# WARNING the ordering of the arguments in the standard is whack so this
# doesn't match that
func preInsertionValidity*(parent, node: Node, before: Node): bool =
  if not parent.isValidParent:
    return false
  if node.isHostIncludingInclusiveAncestor(parent):
    return false
  if before != nil and before.parentNode != parent:
    return false
  if not node.isValidChild:
    return false
  if node of Text and parent of Document:
    return false
  if node of DocumentType and not (parent of Document):
    return false
  if parent of Document:
    if node of DocumentFragment:
      let elems = node.countElementChildren()
      if elems > 1 or node.hasTextChild():
        return false
      elif elems == 1 and (parent.hasElementChild() or
          before != nil and
          (before of DocumentType or before.hasNextDocumentTypeSibling())):
        return false
    elif node of Element:
      if parent.hasElementChild():
        return false
      elif before != nil and (before of DocumentType or
            before.hasNextDocumentTypeSibling()):
        return false
    elif node of DocumentType:
      if parent.hasDocumentTypeChild() or
          before != nil and before.hasPreviousElementSibling() or
          before == nil and parent.hasElementChild():
        return false
  return true # no exception reached

proc insertBefore(parent, child: Node, before: Option[Node]) =
  let before = before.get(nil)
  if parent.preInsertionValidity(child, before):
    assert child.parentNode == nil
    if before == nil:
      parent.childList.add(child)
    else:
      let i = parent.childList.find(before)
      parent.childList.insert(child, i)
    child.parentNode = parent

proc insertBeforeImpl(builder: MiniDOMBuilder, parent, child: Node,
    before: Option[Node]) =
  parent.insertBefore(child, before)

proc insertTextImpl(builder: MiniDOMBuilder, parent: Node, text: string,
    before: Option[Node]) =
  let text = text.toValidUTF8()
  let before = before.get(nil)
  let prevSibling = if before != nil:
    let i = parent.childList.find(before)
    if i == 0:
      nil
    else:
      parent.childList[i - 1]
  elif parent.childList.len > 0:
    parent.childList[^1]
  else:
    nil
  if prevSibling != nil and prevSibling of Text:
    Text(prevSibling).data &= text
  else:
    let text = Text(data: text)
    parent.insertBefore(text, option(before))

proc removeImpl(builder: MiniDOMBuilder, child: Node) =
  if child.parentNode != nil:
    let i = child.parentNode.childList.find(child)
    child.parentNode.childList.delete(i)
    child.parentNode = nil

proc moveChildrenImpl(builder: MiniDOMBuilder, fromNode, toNode: Node) =
  let tomove = @(fromNode.childList)
  fromNode.childList.setLen(0)
  for child in tomove:
    child.parentNode = nil
    toNode.insertBefore(child, none(Node))

proc addAttrsIfMissingImpl(builder: MiniDOMBuilder, handle: Node,
    attrs: Table[MAtom, string]) =
  let element = Element(handle)
  var oldNames = initHashSet[MAtom]()
  for attr in element.attrs:
    oldNames.incl(attr.name)
  for name, value in attrs:
    if name notin oldNames:
      element.attrs.add((NO_PREFIX, NO_NAMESPACE, name, value.toValidUTF8()))
  element.attrs.sort(func(a, b: Attribute): int = cmp(a.name, b.name))

method setEncodingImpl(builder: MiniDOMBuilder, encoding: string):
    SetEncodingResult {.base.} =
  # Provided as a method for minidom_cs to override.
  return SET_ENCODING_CONTINUE

proc newMiniDOMBuilder*(factory: MAtomFactory): MiniDOMBuilder =
  let document = Document(factory: factory)
  let builder = MiniDOMBuilder(
    document: document,
    factory: factory
  )
  return builder

proc parseFromStream(parser: var HTML5Parser[Node, MAtom],
    inputStream: Stream) =
  var buffer {.noinit.}: array[4096, char]
  while true:
    let n = inputStream.readData(addr buffer[0], buffer.len)
    if n == 0: break
    # res can be PRES_CONTINUE or PRES_SCRIPTING. PRES_STOP is only returned
    # on charset switching, and minidom does not support that.
    var res = parser.parseChunk(buffer.toOpenArray(0, n - 1))
    # Important: we must repeat parseChunk with the same contents for the script
    # end tag result, with reprocess = true.
    #
    # (This is only relevant for calls where scripting = true; with scripting =
    # false, PRES_SCRIPT would never be returned.)
    var ip = 0
    while res == PRES_SCRIPT and (ip += parser.getInsertionPoint(); ip != n):
      res = parser.parseChunk(buffer.toOpenArray(ip, n - 1))
  parser.finish()

proc parseHTML*(inputStream: Stream, opts = HTML5ParserOpts[Node, MAtom](),
    factory = newMAtomFactory()): Document =
  ## Read, parse and return an HTML document from `inputStream`, using
  ## parser options `opts` and MAtom factory `factory`.
  ##
  ## `inputStream` is not required to be seekable.
  ##
  ## For a description of `HTML5ParserOpts`, see the `htmlparser` module's
  ## documentation.
  let builder = newMiniDOMBuilder(factory)
  var parser = initHTML5Parser(builder, opts)
  parser.parseFromStream(inputStream)
  return builder.document

proc parseHTMLFragment*(inputStream: Stream, element: Element,
    opts: HTML5ParserOpts[Node, MAtom], factory = newMAtomFactory()):
    seq[Node] =
  ## Read, parse and return the children of an HTML fragment from `inputStream`,
  ## using context element `element` and parser options `opts`.
  ##
  ## For information on `opts` (an `HTML5ParserOpts` object), please consult
  ## the documentation of chame/htmlparser.nim.
  ##
  ## For details on the HTML fragment parsing algorithm, see
  ## https://html.spec.whatwg.org/multipage/parsing.html#parsing-html-fragments
  ##
  ## Note: the members `ctx`, `initialTokenizerState`, `openElementsInit` and
  ## `pushInTemplate` of `opts` are overridden (in accordance with the standard).
  let builder = newMiniDOMBuilder(factory)
  let document = builder.document
  let state = if element.namespace != Namespace.HTML:
    DATA
  else:
    case element.tagType
    of TAG_TITLE, TAG_TEXTAREA: RCDATA
    of TAG_STYLE, TAG_XMP, TAG_IFRAME, TAG_NOEMBED, TAG_NOFRAMES: RAWTEXT
    of TAG_SCRIPT: SCRIPT_DATA
    of TAG_NOSCRIPT: DATA # no scripting
    of TAG_PLAINTEXT: PLAINTEXT
    else: DATA
  let htmlAtom = builder.factory.tagTypeToAtom(TAG_HTML)
  let root = Element(
    localName: htmlAtom,
    namespace: HTML,
    document: document
  )
  document.childList = @[Node(root)]
  var opts = opts
  opts.ctx = some((Node(element), element.localName))
  opts.initialTokenizerState = state
  opts.openElementsInit = @[(Node(root), htmlAtom)]
  opts.pushInTemplate = element.tagType == TAG_TEMPLATE
  var parser = initHTML5Parser(builder, opts)
  parser.parseFromStream(inputStream)
  return root.childList

proc parseHTMLFragment*(s: string, element: Element): seq[Node] =
  ## Convenience wrapper around parseHTMLFragment with opts.
  ##
  ## Read, parse and return the children of an HTML fragment from the string `s`,
  ## using context element `element`.
  ##
  ## For details on the HTML fragment parsing algorithm, see
  ## https://html.spec.whatwg.org/multipage/parsing.html#parsing-html-fragments
  let inputStream = newStringStream(s)
  let opts = HTML5ParserOpts[Node, MAtom](
    isIframeSrcdoc: false,
    scripting: false,
    pushInTemplate: element.tagType == TAG_TEMPLATE
  )
  return parseHTMLFragment(inputStream, element, opts)

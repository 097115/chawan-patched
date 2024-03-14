import std/os
import std/posix
import std/strutils
import std/unicode

import bindings/libregexp
import js/regex
import types/opt
import utils/twtstr

proc lre_check_stack_overflow(opaque: pointer; alloca_size: csize_t): cint
    {.exportc.} =
  return 0

proc parseSection(query: string): tuple[page, section: string] =
  var section = ""
  if query.len > 0 and query[^1] == ')':
    for i in countdown(query.high, 0):
      if query[i] == '(':
        section = query.substr(i + 1, query.high - 1)
        break
  if section != "":
    return (query.substr(0, query.high - 2 - section.len), section)
  return (query, "")

func processBackspace(line: string): string =
  var s = ""
  var i = 0
  var thiscs = 0 .. -1
  var bspace = false
  var inU = false
  var inB = false
  var pendingInU = false
  var pendingInB = false
  template flushChar =
    if pendingInU != inU:
      s &= (if inU: "</u>" else: "<u>")
      inU = pendingInU
    if pendingInB != inB:
      s &= (if inB: "</b>" else: "<b>")
      inB = pendingInB
    if thiscs.len > 0:
      let cs = case line[thiscs.a]
      of '&': "&amp;"
      of '<': "&lt;"
      of '>': "&gt;"
      else: line.substr(thiscs.a, thiscs.b)
      s &= cs
    thiscs = i ..< i + n
    pendingInU = false
    pendingInB = false
  while i < line.len:
    # this is the same "sometimes works" algorithm as in ansi2html
    if line[i] == '\b' and thiscs.len > 0:
      bspace = true
      inc i
      continue
    let n = line.runeLenAt(i)
    if thiscs.len == 0:
      thiscs = i ..< i + n
      i += n
      continue
    if bspace and thiscs.len > 0:
      if line[i] == '_' and not pendingInU and line[thiscs.a] != '_':
        pendingInU = true
      elif line[thiscs.a] == '_' and not pendingInU and line[i] != '_':
        # underscore comes first; set thiscs to the current charseq
        thiscs = i ..< i + n
        pendingInU = true
      elif line[i] == '_' and line[thiscs.a] == '_':
        if pendingInB:
          pendingInU = true
        else:
          pendingInB = true
      elif not pendingInB:
        pendingInB = true
      bspace = false
    else:
      flushChar
    i += n
  let n = 0
  flushChar
  pendingInU = false
  pendingInB = false
  flushChar
  return s

proc isCommand(paths: seq[string]; s: string): bool =
  for p in paths:
    if fileExists(p & s):
      return true
  false

iterator myCaptures(captures: var seq[RegexCapture]; target: int;
    offset: var int): RegexCapture =
  for cap in captures.mitems:
    if cap.i == target:
      cap.s += offset
      cap.e += offset
      yield cap

proc processManpage(file: File) =
  template re(s: static string): Regex =
    let r = s.compileRegex({LRE_FLAG_GLOBAL, LRE_FLAG_UTF16})
    if r.isNone:
      stdout.write(s & ": " & r.error)
      return
    r.get
  # regexes partially from w3mman2html
  let linkRe = re"(https?|ftp)://[\w/~.-]+"
  let mailRe = re"(mailto:|)(\w[\w.-]*@[\w-]+\.[\w.-]*)"
  let fileRe = re"(file:)?[/~][\w/~.-]+[\w/]"
  let includeRe = re"#include(</?[bu]>|\s)*&lt;([\w./-]+)"
  let manRe = re"(</?[bu]>)*(\w[\w.-]*)(</?[bu]>)*(\([0-9nlx]\w*\))"
  var paths: seq[string] = @[]
  for p in getEnv("PATH").split(':'):
    var i = p.high
    while i > 0 and p[i] == '/':
      dec i
    paths.add(p.substr(0, i) & "/")
  var line: string
  var wasBlank = false
  while file.readLine(line):
    if line == "":
      if wasBlank:
        continue
      wasBlank = true
    else:
      wasBlank = false
    var line = line.processBackspace()
    if (var res = linkRe.exec(line); res.success):
      var offset = 0
      for cap in res.captures.myCaptures(0, offset):
        let s = line[cap.s..<cap.e]
        let link = "<a href='" & s & "'>" & s & "</a>"
        line[cap.s..<cap.e] = link
        offset += link.len - (cap.e - cap.s)
    if (var res = mailRe.exec(line); res.success):
      var offset = 0
      for cap in res.captures.myCaptures(2, offset):
        let s = line[cap.s..<cap.e]
        let link = "<a href='mailto:" & s & "'>" & s & "</a>"
        line[cap.s..<cap.e] = link
        offset += link.len - (cap.e - cap.s)
    if (var res = fileRe.exec(line); res.success):
      var offset = 0
      for cap in res.captures.myCaptures(0, offset):
        let s = line[cap.s..<cap.e]
        let target = s.expandTilde()
        if not fileExists(target) and not symlinkExists(target) and
            not dirExists(target):
          continue
        let link = if paths.isCommand(target):
          "<a href='man:" & target.afterLast('/') & "'>" & s & "</a>"
        else:
          "<a href='file:" & target & "'>" & s & "</a>"
        line[cap.s..<cap.e] = link
        offset += link.len - (cap.e - cap.s)
    if (var res = includeRe.exec(line); res.success):
      var offset = 0
      for cap in res.captures.myCaptures(2, offset):
        let s = line[cap.s..<cap.e]
        const includePaths = [
          "/usr/include/",
          "/usr/local/include/",
          "/usr/X11R6/include/",
          "/usr/X11/include/",
          "/usr/X/include/",
          "/usr/include/X11/"
        ]
        for path in includePaths:
          let file = path & s
          if fileExists(file):
            let link = "<a href='file:" & file & "'>" & s & "</a>"
            line[cap.s..<cap.e] = link
            offset += link.len - (cap.e - cap.s)
            break
    if (var res = manRe.exec(line); res.success):
      var offset = 0
      for j, cap in res.captures.mpairs:
        if cap.i == 0:
          cap.s += offset
          cap.e += offset
          var manCap = res.captures[j + 2]
          manCap.s += offset
          manCap.e += offset
          var secCap = res.captures[j + 4]
          secCap.s += offset
          secCap.e += offset
          let man = line[manCap.s..<manCap.e]
          let cat = man & line[secCap.s..<secCap.e]
          let link = "<a href='man:" & cat & "'>" & man & "</a>"
          line[manCap.s..<manCap.e] = link
          offset += link.len - (manCap.e - manCap.s)
    stdout.write(line & "\n")

proc doMan(man, keyword, section: string) =
  let sectionOpt = if section == "": "" else: " -s " & section
  let cmd = "GROFF_NO_SGR=1 MAN_KEEP_FORMATTING=1 " &
    man & sectionOpt & " " & keyword & " 2>&1"
  let file = popen(cstring(cmd), "r")
  if file == nil:
    stdout.write("Cha-Control: ConnectionError 1 failed to run " & cmd)
    return
  var line0: string
  if not file.readLine(line0) or file.endOfFile():
    discard file.pclose()
    if line0.startsWith("man: "):
      line0 = line0.after(' ')
    stdout.write("Cha-Control: ConnectionError 4 " & line0)
    return
  var manword = keyword
  if section != "":
    manword &= '(' & section & ')'
  stdout.write("""Content-Type: text/html

<title>man """ & manword & """</title>
<pre>""" & line0 & "\n")
  file.processManpage()
  discard file.pclose()

proc doLocal(man, keyword: string) =
  let cmd = "GROFF_NO_SGR=1 MAN_KEEP_FORMATTING=1 " &
    man & " -l " & keyword & " 2>/dev/null"
  let file = popen(cstring(cmd), "r")
  if file == nil:
    stdout.write("Cha-Control: ConnectionError 1 failed to run " & cmd)
    return
  stdout.write("""Content-Type: text/html

<title>man -l """ & keyword & """</title>
<h1>man -l <b>""" & keyword & """</b></h1>
<pre>""")
  file.processManpage()
  discard file.pclose()

proc doKeyword(man, keyword, section: string) =
  let sectionOpt = if section == "": "" else: " -s " & section
  let cmd = man & sectionOpt & " -k " & keyword & " 2>/dev/null"
  let file = popen(cstring(cmd), "r")
  if file == nil:
    stdout.write("Cha-Control: ConnectionError 1 failed to run " & cmd)
    return
  stdout.write("Content-Type: text/html\n\n")
  stdout.write("<title>man" & sectionOpt & " -k " & keyword & "</title>\n")
  stdout.write("<h1>man" & sectionOpt & " -k <b>" & keyword & "</b></h1>\n")
  stdout.write("<ul>")
  var line: string
  template die =
    stdout.write("Error parsing line! " & line)
    return
  while file.readLine(line):
    if line.len == 0:
      stdout.write("\n")
      continue
    # collect titles
    var titles: seq[string] = @[]
    var i = 0
    while true:
      let title = line.until({'(', ','}, i)
      i += title.len
      titles.add(title)
      if i >= line.len or line[i] == '(':
        break
      i = line.skipBlanks(i + 1)
    # collect section
    if line[i] != '(': die
    let sectionText = line.substr(i, line.find(')', i))
    i += sectionText.len
    # create line
    var section = sectionText.until(',') # for multiple sections, take first
    if section[^1] != ')':
      section &= ')'
    var s = "<li>"
    for i, title in titles:
      let title = title.htmlEscape()
      s &= "<a href='man:" & title & section & "'>" & title & "</a>"
      if i < titles.high:
        s &= ", "
    s &= sectionText
    s &= line.substr(i)
    s &= "\n"
    stdout.write(s)

proc main() =
  var man = getEnv("MANCHA_MAN")
  if man == "":
    man = "/usr/bin/man"
    if not fileExists(man):
      man = "/bin/man"
      if not fileExists(man):
        man = "/usr/local/bin/man"
        if not fileExists(man):
          man = "/usr/bin/env man"
    doAssert getAppFilename() != man # don't accidentally fork bomb ourselves
  let query = percentDecode(getEnv("QUERY_STRING"))
  if query.startsWith("man:"):
    let (keyword, section) = parseSection(query.after(':'))
    doMan(man, keyword, section)
  elif query.startsWith("man-k:"):
    let (keyword, section) = parseSection(query.after(':'))
    doKeyword(man, keyword, section)
  elif query.startsWith("man-l:"):
    doLocal(man, query.after(':'))
  else:
    stdout.write("Cha-Control: ConnectionError 1 invalid invocation")

main()
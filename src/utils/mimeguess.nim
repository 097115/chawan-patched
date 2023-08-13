import algorithm
import streams
import tables

import config/mimetypes

const DefaultGuess* = block:
  let ss = newStringStream(staticRead"res/mime.types")
  parseMimeTypes(ss)

proc guessContentType*(path: string, fallback = "text/plain",
    guess = DefaultGuess): string =
  var i = path.len - 1
  var n = 0
  while i > 0:
    if path[i] == '/':
      return fallback
    if path[i] == '.':
      n = i
      break
    dec i
  if n > 0:
    let ext = path.substr(n + 1)
    if ext in guess:
      return guess[ext]
  return fallback

const JavaScriptTypes = [
  "application/ecmascript",
  "application/javascript",
  "application/x-ecmascript",
  "application/x-javascript",
  "text/ecmascript",
  "text/javascript",
  "text/javascript1.0",
  "text/javascript1.1",
  "text/javascript1.2",
  "text/javascript1.3",
  "text/javascript1.4",
  "text/javascript1.5",
  "text/jscript",
  "text/livescript",
  "text/x-ecmascript",
  "text/x-javascript"
]

proc isJavaScriptType*(s: string): bool =
  return binarySearch(JavaScriptTypes, s) != -1
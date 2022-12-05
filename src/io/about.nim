import streams
import tables

import io/request
import ips/serialize
import types/url

const cha = staticRead"res/cha.html"
const Headers = {
  "Content-Type": "text/html"
}.toTable()

proc loadAbout*(request: Request, ostream: Stream) =
  if request.url.pathname == "cha":
    ostream.swrite(0)
    ostream.swrite(200) # ok
    let headers = newHeaderList(Headers)
    ostream.swrite(headers)
    ostream.write(cha)
  else:
    ostream.swrite(-1)
  ostream.flush()

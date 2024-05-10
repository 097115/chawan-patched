type
  DynBufReallocFunc = proc(opaque, p: pointer; size: csize_t): pointer {.cdecl.}

  CharRange* = object
    len*: cint # in points, always even
    size*: cint
    points*: ptr uint32 # points sorted by increasing value
    mem_opaque*: pointer
    realloc_func*: DynBufReallocFunc

  UnicodeNormalizationEnum* {.size: sizeof(cint).} = enum
    UNICODE_NFC, UNICODE_NFD, UNICODE_NKFC, UNICODE_NKFD

{.passc: "-Ilib/".}

{.push header: "quickjs/libunicode.h", importc.}

proc cr_init*(cr: ptr CharRange; mem_opaque: pointer;
  realloc_func: DynBufReallocFunc)

proc cr_free*(cr: ptr CharRange)

proc unicode_normalize*(pdst: ptr ptr uint32; src: ptr uint32; src_len: cint;
  n_type: UnicodeNormalizationEnum; opaque: pointer;
  realloc_func: DynBufReallocFunc): cint

proc unicode_script*(cr: ptr CharRange; script_name: cstring; is_ext: cint):
  cint
proc unicode_prop*(cr: ptr CharRange; prop_name: cstring): cint
proc unicode_general_category*(cr: ptr CharRange; gc_name: cstring): cint

const LRE_CC_RES_LEN_MAX* = 3

# conv_type:
# 0 = to upper
# 1 = to lower
# 2 = case folding
# res must be an array of LRE_CC_RES_LEN_MAX
proc lre_case_conv*(res: ptr UncheckedArray[uint32]; c: uint32;
  conv_type: cint): cint

proc lre_is_space*(c: uint32): cint

{.pop.}

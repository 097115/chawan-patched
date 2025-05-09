# Bonus

Misc modules and configurations - mostly just personal scripts that I
don't want to copy around otherwise...

## Install

Run `make install-{filename}`. For example, to install git.cgi, you run
`make install-git.cgi`.

Warning: some of the installers will modify your ~/.urimethodmap file.
Because the entries are inserted to the file's start, you can usually
just remove these if you no longer want to use the script.

Also, the /cgi-bin/ directory is assumed to be configured as the default
(~/.chawan/cgi-bin or ~/.config/chawan/cgi-bin if you use XDG basedir).
Use `make CHA_CGI_DIR=...` to override this.

## Summary

Additional documentation is embedded at the beginning of each file.
Please read it. (Note that the Makefile automates the installation
instructions, so you can skip those.)

### [filei.cgi](filei.cgi)

Album view of a directory. Requires `buffer.images = true`.

### [git.cgi](git.cgi)

Turns git command output into hypertext; quite useful, albeit a bit
slow.

It's also a demonstration of a combined CLI command and CGI script.

### [libfetch-http.c](libfetch-http.c)

CGI script to replace the default http handler with FreeBSD libfetch.

Just for fun; it's not very usable in practice, because libfetch is
designed to handle file downloads, not web browsing.

### [magnet.cgi](magnet.cgi)

A `magnet:` URL handler. It can forward magnet links to transmission.

### [newhttp](newhttp/)

WIP new HTTP(S) CGI handler.  For now, the only difference between
this and the current one is that this uses tinfl for decompression.

Still TODO:

* figure out what ciphers to allow
* keep-alive (loader needs work first)
* zstd
* HTTP/2
* sandbox

### [stbir2](stbir2/)

By default, Chawan uses stb_image_resize for resizing images, but there
is a newer and improved (as well as much larger) version, called
`stb_image_resize2`. This script replaces the default image resizer
with that.

To compile this, the Makefile will try download the header file from
GitHub: <https://raw.githubusercontent.com/nothings/stb/master/stb_image_resize2.h>

but you can also just manually put the header in the directory, and then
nothing will be downloaded.

### [trans.cgi](trans.cgi)

Uses [translate-shell](https://github.com/soimort/translate-shell) to
translate words.

### [w3m.toml](w3m.toml)

A (somewhat) w3m-compatible keymap. Mainly for demonstration purposes.

Note: this does not have an installer. Copy/include it manually.

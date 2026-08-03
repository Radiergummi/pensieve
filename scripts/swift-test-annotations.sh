#!/bin/sh
# Pass `swift test` output through unchanged, additionally emitting a GitHub Actions
# error annotation for each Swift Testing failure so it surfaces on the file and line
# in the diff rather than only in the raw log.
#
# This exists because xcbeautify's github-actions renderer does not attach filenames
# for Swift Testing output (cpisciotta/xcbeautify#328). It is a filter only: it never
# changes the exit status, so callers need `set -o pipefail` to fail the step.
#
# Input lines look like:
#   ✘ Test someTest() recorded an issue at SomeTests.swift:194:3: Expectation failed: ...
# Swift Testing reports only the basename, so basenames are resolved against the repo.

set -eu

map=$(mktemp)
trap 'rm -f "$map"' EXIT
find Sources Tests -name '*.swift' 2>/dev/null | awk -F/ '{ print $NF "\t" $0 }' | sort -u >"$map"

exec awk -v mapfile="$map" '
  BEGIN {
    FS = "\n"
    while ((getline line < mapfile) > 0) {
      split(line, f, "\t")
      # First match wins; duplicate basenames fall back to the earliest path.
      if (!(f[1] in path)) path[f[1]] = f[2]
    }
  }

  { print }

  /recorded an issue at / {
    marker = "recorded an issue at "
    rest = substr($0, index($0, marker) + length(marker))

    c1 = index(rest, ":"); if (c1 == 0) next
    file = substr(rest, 1, c1 - 1)
    r = substr(rest, c1 + 1)

    c2 = index(r, ":"); if (c2 == 0) next
    line_no = substr(r, 1, c2 - 1)
    r = substr(r, c2 + 1)

    # A column is usually present ("194:3: msg") but not guaranteed.
    c3 = index(r, ":")
    if (c3 > 0 && substr(r, 1, c3 - 1) ~ /^[0-9]+$/) {
      col = substr(r, 1, c3 - 1)
      msg = substr(r, c3 + 2)
    } else {
      col = ""
      msg = r
      sub(/^ +/, "", msg)
    }

    name = ""
    if (match($0, /Test [^ ]+\(\)/)) name = substr($0, RSTART + 5, RLENGTH - 5)

    p = (file in path) ? path[file] : file

    # Workflow commands are line-oriented; % and CR must be escaped.
    gsub(/%/, "%25", msg)
    gsub(/\r/, "", msg)
    if (name != "") msg = name " — " msg

    if (col != "")
      printf "::error file=%s,line=%s,col=%s::%s\n", p, line_no, col, msg
    else
      printf "::error file=%s,line=%s::%s\n", p, line_no, msg
  }
'

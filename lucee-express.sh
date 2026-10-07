#!/bin/sh
# lucee-express.sh - assemble Lucee Express from Maven repositories (Maven Central by default)
# instead of downloading lucee-express-<version>.zip from cdn.lucee.org.
#
#   ./lucee-express.sh <luceeVersion> <targetDir>
#
# Environment:
#   LUCEE_EXPRESS_REPOS  space-separated repository URLs, tried in order (default https://repo1.maven.org/maven2)
#                        file:// URLs work too.
#   LUCEE_EXPRESS_CACHE  cache dir in Maven layout (default ~/.m2/repository); repeat runs download nothing.
#   LUCEE_EXPRESS_FORCE=1  replace an existing targetDir
#
# Needs: sh, curl or wget, sha256sum/sha1sum or shasum, tar (GNU or bsdtar), unzip (or bsdtar).
# Same layout rules as LuceeExpress.java (lucee.express.layout=1):
#   tar.gz deps -> extracted into the root without the top folder and without webapps/
#   jar deps    -> lib/ext/<artifactId>-<version>[-<classifier>].jar
#   lucee-express-<v>-template.zip -> extracted over the root, last
set -eu

[ $# -eq 2 ] || { echo "usage: $0 <luceeVersion> <targetDir>" >&2; exit 2; }
VERSION=$1
TARGET=$2
REPOS=${LUCEE_EXPRESS_REPOS:-https://repo1.maven.org/maven2}
CACHE=${LUCEE_EXPRESS_CACHE:-$HOME/.m2/repository}
STATS=$(mktemp)

log() { echo "  $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

if [ -e "$TARGET" ]; then
  [ "${LUCEE_EXPRESS_FORCE:-0}" = 1 ] || die "target exists: $TARGET (set LUCEE_EXPRESS_FORCE=1)"
  rm -rf "$TARGET"
fi

# --- helpers -------------------------------------------------------------------------------------
get() { # get <url> <dest>   (returns 1 on 404/any error)
  case $1 in
    file://*) [ -f "${1#file://}" ] && cp "${1#file://}" "$2" ;;
    *) if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$2" "$1" 2>/dev/null
       else wget -q -O "$2" "$1"; fi ;;
  esac
}
digest() { # digest <256|1> <file>
  if command -v sha${1}sum >/dev/null 2>&1; then sha${1}sum "$2" | cut -d' ' -f1
  else shasum -a "$1" "$2" | cut -d' ' -f1; fi
}
verify_cached() { # verify_cached <file>  -> 0 if ok or no checksum file stored (e.g. written by Maven)
  for a in 256 1; do
    if [ -f "$1.sha$a" ]; then
      [ "$(digest $a "$1")" = "$(cut -d' ' -f1 < "$1.sha$a" | tr 'A-F' 'a-f')" ]; return $?
    fi
  done
  return 0
}
fetch() { # fetch <g> <a> <v> <type> <classifier|-> ; prints the local path
  g=$1 a=$2 v=$3 t=$4 c=$5
  f="$a-$v"; [ "$c" = - ] || f="$f-$c"; f="$f.$t"
  rel="$(echo "$g" | tr . /)/$a/$v/$f"
  dest="$CACHE/$rel"
  if [ -f "$dest" ]; then
    if verify_cached "$dest"; then log "cache   $g:$a:$v:$t:$c"; echo "$dest"; return 0; fi
    log "cache   $rel failed checksum, re-downloading"; rm -f "$dest"
  fi
  mkdir -p "$(dirname "$dest")"
  for repo in $REPOS; do
    url="${repo%/}/$rel"
    alg=
    for a2 in 256 1; do
      if get "$url.sha$a2" "$dest.sum" ; then alg=$a2; break; fi
    done
    [ -n "$alg" ] || continue                       # not in this repo
    want=$(tr -d '\r' < "$dest.sum" | awk '{print tolower($1)}'); rm -f "$dest.sum"
    get "$url" "$dest.part" || die "download failed: $url"
    have=$(digest $alg "$dest.part")
    [ "$have" = "$want" ] || { rm -f "$dest.part"; die "checksum mismatch for $url (sha$alg $have != $want)"; }
    echo "$want" > "$dest.sha$alg"
    mv "$dest.part" "$dest"
    size=$(wc -c < "$dest" | tr -d ' ')
    echo "$size" >> "$STATS"
    log "fetched $g:$a:$v:$t:$c ($((size / 1024)) KB, sha$alg ok) from $repo"
    echo "$dest"; return 0
  done
  die "$g:$a:$v:$t:$c not found in: $REPOS"
}
unzip_to() { # unzip_to <zip> <dir>
  if command -v unzip >/dev/null 2>&1; then unzip -q -o "$1" -d "$2"
  else tar -xf "$1" -C "$2"; fi          # bsdtar (macOS, Windows) reads zip
}

# --- POM -----------------------------------------------------------------------------------------
POM=$(fetch org.lucee lucee-express "$VERSION" pom -)
# prints "P name value" for <properties> and "D g a v type classifier" for <dependencies> (outside <exclusions>)
PARSED=$(awk -v RS='<' '
  { tag=$0; sub(/>.*/, "", tag); sub(/[ \t\r\n].*/, "", tag); val=$0; sub(/^[^>]*>/, "", val); gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", val) }
  tag=="properties"{inp=1; next} tag=="/properties"{inp=0}
  inp && tag !~ /^[\/!]/ { print "P", tag, val }
  tag=="exclusions"{ex=1} tag=="/exclusions"{ex=0}
  tag=="dependency"{ind=1; g=a=v=t=c=o=s=""}
  ind && !ex && tag=="groupId"{g=val}    ind && !ex && tag=="artifactId"{a=val}
  ind && !ex && tag=="version"{v=val}    ind && !ex && tag=="type"{t=val}
  ind && !ex && tag=="classifier"{c=val} ind && !ex && tag=="optional"{o=val}
  ind && !ex && tag=="scope"{s=val}
  tag=="/dependency"{ ind=0; if (o!="true" && s!="test" && s!="provided") print "D", g, a, v, (t==""?"jar":t), (c==""?"-":c) }
' "$POM")
LAYOUT=$(echo "$PARSED" | awk '$1=="P" && $2=="lucee.express.layout"{print $3}')
[ -z "$LAYOUT" ] || [ "$LAYOUT" -le 1 ] || die "lucee-express layout $LAYOUT is newer than this script supports (1)"
expand() { # replace ${prop} with values from <properties>
  s=$1
  for kv in $(echo "$PARSED" | awk '$1=="P"{print $2"="$3}'); do
    k=${kv%%=*}; val=${kv#*=}
    s=$(printf '%s' "$s" | sed "s|\${$k}|$val|g")
  done
  printf '%s' "$s"
}

# --- resolve everything, then lay out into a temp dir ----------------------------------------------
PARENT=$(dirname "$TARGET"); mkdir -p "$PARENT"
TMP=$(mktemp -d "$PARENT/.lucee-express.XXXXXX"); chmod 755 "$TMP"
trap 'rm -rf "$TMP" "$STATS"' EXIT
JARS=""
echo "$PARSED" | awk '$1=="D"' > "$TMP/.deps"
while read -r _ g a v t c; do
  v=$(expand "$v")
  file=$(fetch "$g" "$a" "$v" "$t" "$c")
  case $t in
    tar.gz|tgz) tar -xzf "$file" -C "$TMP" --strip-components=1 --exclude='*/webapps' --exclude='*/webapps/*' ;;
    jar) n="$a-$v"; [ "$c" = - ] || n="$n-$c"; JARS="$JARS $file:$n.jar" ;;
    *) die "unsupported dependency type $t ($g:$a)" ;;
  esac
done < "$TMP/.deps"
rm -f "$TMP/.deps"
mkdir -p "$TMP/lib/ext"
for j in $JARS; do cp "${j%:*}" "$TMP/lib/ext/${j##*:}"; done
TEMPLATE=$(fetch org.lucee lucee-express "$VERSION" zip template)
unzip_to "$TEMPLATE" "$TMP"
find "$TMP" -name '*.sh' -exec chmod +x {} +
mv "$TMP" "$TARGET"
trap - EXIT
MB=$(awk '{s+=$1} END {printf "%.1f", s/1048576}' "$STATS"); rm -f "$STATS"
echo "Lucee Express $VERSION assembled in $TARGET ($MB MB downloaded)"

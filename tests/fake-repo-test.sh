#!/bin/sh
# Builds a tiny fake Maven repository (file:) and checks layout, cache hit, not-found and checksum mismatch
# for LuceeExpress.java and lucee-express.sh, and that both produce identical trees.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
V=9.9.9.9
R=$W/repo
mkdir -p "$W/tc/apache-tomcat-1.0/bin" "$W/tc/apache-tomcat-1.0/conf" "$W/tc/apache-tomcat-1.0/webapps/docs" "$W/tpl/conf" "$W/tpl/webapps/ROOT"
echo catalina > "$W/tc/apache-tomcat-1.0/bin/catalina.sh"; chmod 755 "$W/tc/apache-tomcat-1.0/bin/catalina.sh"
echo stock > "$W/tc/apache-tomcat-1.0/conf/server.xml"; echo docs > "$W/tc/apache-tomcat-1.0/webapps/docs/x.txt"
echo lucee > "$W/tpl/conf/server.xml"; echo hi > "$W/tpl/webapps/ROOT/index.cfm"
add() { # g a v ext file [classifier]
  d="$R/$(echo "$1" | tr . /)/$2/$3"; mkdir -p "$d"; n="$2-$3${6:+-$6}.$4"; cp "$5" "$d/$n"
  (cd "$d" && { sha256sum "$n" 2>/dev/null || shasum -a 256 "$n"; } | cut -d' ' -f1 > "$n.sha256")
}
(cd "$W/tc" && tar czf "$W/tomcat.tar.gz" apache-tomcat-1.0)
(cd "$W/tpl" && zip -qr "$W/template.zip" .)
echo jar1 > "$W/lucee.jar"; echo jar2 > "$W/api.jar"
cat > "$W/express.pom" <<P
<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>
<groupId>org.lucee</groupId><artifactId>lucee-express</artifactId><version>$V</version><packaging>pom</packaging>
<properties><lucee.express.layout>1</lucee.express.layout></properties>
<dependencies>
<dependency><groupId>org.apache.tomcat</groupId><artifactId>tomcat</artifactId><version>1.0</version><type>tar.gz</type></dependency>
<dependency><groupId>org.lucee</groupId><artifactId>lucee</artifactId><version>$V</version></dependency>
<dependency><groupId>javax.x</groupId><artifactId>api</artifactId><version>1.0</version></dependency>
</dependencies></project>
P
add org.lucee lucee-express $V pom "$W/express.pom"
add org.lucee lucee-express $V zip "$W/template.zip" template
add org.apache.tomcat tomcat 1.0 tar.gz "$W/tomcat.tar.gz"
add org.lucee lucee $V jar "$W/lucee.jar"
add javax.x api 1.0 jar "$W/api.jar"

fail() { echo "FAIL: $*" >&2; exit 1; }
java "$HERE/LuceeExpress.java" $V "$W/out-java" --repo "file://$R" --cache "$W/c1" >/dev/null || fail "java assemble"
LUCEE_EXPRESS_REPOS="file://$R" LUCEE_EXPRESS_CACHE="$W/c2" sh "$HERE/lucee-express.sh" $V "$W/out-sh" >/dev/null 2>&1 || fail "sh assemble"
for t in out-java out-sh; do
  [ -f "$W/$t/bin/catalina.sh" ] && [ -x "$W/$t/bin/catalina.sh" ] || fail "$t: catalina.sh"
  [ "$(cat "$W/$t/conf/server.xml")" = lucee ] || fail "$t: template must override conf/server.xml"
  [ -f "$W/$t/webapps/ROOT/index.cfm" ] && [ ! -e "$W/$t/webapps/docs" ] || fail "$t: webapps rule"
  [ -f "$W/$t/lib/ext/lucee-$V.jar" ] && [ -f "$W/$t/lib/ext/api-1.0.jar" ] || fail "$t: lib/ext"
done
diff -r "$W/out-java" "$W/out-sh" || fail "java and sh trees differ"
# cache hit: a second run with the repo gone must succeed
mv "$R" "$R.gone"
java "$HERE/LuceeExpress.java" $V "$W/out-cached" --repo "file://$R" --cache "$W/c1" >/dev/null || fail "cache hit"
mv "$R.gone" "$R"
# not found
if java "$HERE/LuceeExpress.java" 0.0.0.1 "$W/out-nf" --repo "file://$R" --cache "$W/c3" >/dev/null 2>&1; then fail "not-found must fail"; fi
# checksum mismatch
echo 0000 > "$R/org/lucee/lucee/$V/lucee-$V.jar.sha256"
if java "$HERE/LuceeExpress.java" $V "$W/out-bad" --repo "file://$R" --cache "$W/c4" >/dev/null 2>&1; then fail "checksum mismatch must fail"; fi
[ ! -e "$W/out-bad" ] || fail "no half tree on failure"
echo "OK"

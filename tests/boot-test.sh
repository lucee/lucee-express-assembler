#!/bin/sh
# boot-test.sh <expressDir> <expectedVersion> : start a copy of an assembled express dir, request a CFML page, stop it
set -eu
SRC=$1; WANT=$2; RUN=$(dirname "$SRC")/run-$(basename "$SRC")
rm -rf "$RUN"; cp -a "$SRC" "$RUN"
echo '<cfoutput>#server.lucee.version# on #server.servlet.name#, Java #server.java.version#</cfoutput>' > "$RUN/webapps/ROOT/version.cfm"
"$RUN/bin/catalina.sh" run > "$RUN.log" 2>&1 &
PID=$!
i=0; OUT=""
while [ $i -lt 120 ]; do
  OUT=$(curl -s -m 5 http://127.0.0.1:8888/version.cfm || true)
  case $OUT in *"$WANT"*) break ;; esac
  sleep 1; i=$((i+1))
done
INDEX=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8888/)
"$RUN/bin/catalina.sh" stop > /dev/null 2>&1 || true
# Lucee leaves non-daemon threads behind, so the JVM may not exit after a clean Tomcat stop: give it 15 s, then kill
j=0; while kill -0 $PID 2>/dev/null && [ $j -lt 15 ]; do sleep 1; j=$((j+1)); done
if kill -0 $PID 2>/dev/null; then pkill -f "catalina.base=$RUN " || true; pkill -f "$RUN/" || true; STOP="JVM killed after stop"; else STOP="JVM exited after stop"; fi
wait $PID 2>/dev/null || true
case $OUT in *"$WANT"*) echo "OK   $(basename "$SRC"): /version.cfm -> '$OUT' (after ~${i}s), / -> HTTP $INDEX; $STOP" ;;
  *) echo "FAIL $(basename "$SRC"): got '$OUT'"; tail -20 "$RUN.log"; exit 1 ;; esac

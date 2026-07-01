#!/usr/bin/env bash
# E2E test for the Claude 대화 panel: text send, multi-turn context (--resume),
# image attachment (base64 -> disk -> claude reads it), and /chat-img serving.
# Drives the real HTTP API against a headless throwaway instance. Calls `claude -p`
# for real, so it needs the claude CLI installed and costs a few tokens.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=".build/debug/ConditionManager"
[ -x "$BIN" ] || { echo "build first: swift build"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not installed"; exit 0; }

DATA_DIR="$(mktemp -d)"; ERRLOG="$(mktemp)"
PASS=0; FAIL=0
cleanup(){ [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null; rm -rf "$DATA_DIR" "$ERRLOG"; }
trap cleanup EXIT
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

CM_DATA_DIR="$DATA_DIR" CM_DASHBOARD=1 "$BIN" >/dev/null 2>"$ERRLOG" &
APP_PID=$!
PORT=""
for _ in $(seq 1 50); do
  [ -f "$DATA_DIR/dashboard.port" ] && PORT="$(cat "$DATA_DIR/dashboard.port" 2>/dev/null)"
  [ -n "$PORT" ] && break; sleep 0.2
done
[ -n "$PORT" ] || { echo "FAIL: no port"; cat "$ERRLOG"; exit 1; }
BASE="http://127.0.0.1:$PORT"
echo "server up on $BASE"

post(){ curl -s -m 200 -X POST "$BASE$1" -H 'Content-Type: application/json' -d "$2"; }
chat_json(){ curl -s "$BASE/api/chat"; }
nmsgs(){ chat_json | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["messages"]))'; }
last_assistant(){ chat_json | python3 -c 'import sys,json
m=[x for x in json.load(sys.stdin)["messages"] if x["role"]=="assistant"]
print(m[-1]["text"] if m else "")'; }

echo "[1] chat starts empty"
[ "$(nmsgs)" = "0" ] && ok "no messages" || ng "expected empty"

echo "[2] text send -> user + assistant recorded, assistant non-empty"
R=$(post /api/chat/send '{"text":"Reply with exactly the word PONG and nothing else.","model":"auto"}')
echo "    assistant: $(echo "$R" | python3 -c 'import sys,json;m=json.load(sys.stdin)["messages"];print(repr(m[-1]["text"][:60]))' 2>/dev/null)"
[ "$(nmsgs)" = "2" ] && ok "user+assistant stored" || ng "message count wrong ($(nmsgs))"
echo "$(last_assistant)" | grep -qi "pong" && ok "assistant answered PONG" || ng "assistant did not answer PONG"

echo "[3] multi-turn context via --resume"
post /api/chat/send '{"text":"My secret codeword is BANANA77. Remember it.","model":"auto"}' >/dev/null
post /api/chat/send '{"text":"What was my secret codeword? Reply with only the codeword.","model":"auto"}' >/dev/null
echo "    recall: $(last_assistant | head -c 60)"
last_assistant | grep -qi "BANANA77" && ok "context preserved across turns" || ng "context NOT preserved"

echo "[4] image attachment -> claude reads it (red png)"
DATAURL=$(python3 - <<'PY'
import zlib,struct,base64
def png(w,h,rgb):
    def ch(t,d): return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
    raw=b''.join(b'\x00'+bytes(rgb)*w for _ in range(h))
    return b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack(">IIBBBBB",w,h,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b'')
print("data:image/png;base64,"+base64.b64encode(png(100,100,(220,20,20))).decode())
PY
)
post /api/chat/reset '{}' >/dev/null
python3 - "$BASE" "$DATAURL" <<'PY'
import sys,json,urllib.request
base,dataurl=sys.argv[1],sys.argv[2]
body=json.dumps({"text":"What is the dominant color of the attached image? Reply with one word.","model":"auto","images":[{"name":"x.png","data":dataurl}]}).encode()
req=urllib.request.Request(base+"/api/chat/send",data=body,headers={"Content-Type":"application/json"})
d=json.load(urllib.request.urlopen(req,timeout=200))
print("    vision:",repr(d["messages"][-1]["text"][:60]))
open("/tmp/cm_chat_resp.json","w").write(json.dumps(d))
PY
last_assistant | grep -qi "red\|빨" && ok "claude read the attached image" || ng "image not read"

echo "[5] /chat-img serves the stored attachment"
IMGURL=$(chat_json | python3 -c 'import sys,json
for m in json.load(sys.stdin)["messages"]:
    if m.get("images"): print(m["images"][0]); break')
echo "    img url: $IMGURL"
if [ -n "$IMGURL" ]; then
  CT=$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "$BASE$IMGURL")
  echo "    GET $IMGURL -> $CT"
  echo "$CT" | grep -q "200 image/" && ok "image served inline" || ng "image not served"
else ng "no image url in conversation"; fi

echo "[6] reset clears the conversation"
post /api/chat/reset '{}' >/dev/null
[ "$(nmsgs)" = "0" ] && ok "conversation cleared" || ng "reset failed"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]

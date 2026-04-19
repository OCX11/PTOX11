#!/bin/bash
# setup_push.sh — one-time setup for PTOX11 PWA push notifications
#
# What this does:
#   1. Starts push_server.py on port 5055
#   2. Creates a persistent Cloudflare Tunnel (stable URL, survives reboots)
#   3. Patches docs/notify.html with the tunnel URL
#   4. Installs launchd plists for push_server + cloudflared
#   5. Prints the subscribe URL to share with others
#
# Run once: bash setup_push.sh
# After running, push_server and cloudflared auto-start on boot.

set -e
PROJ="/Users/claw/porsche-tracker"
PUSH_PORT=5055
PLIST_DIR="$HOME/Library/LaunchAgents"

echo "=== PTOX11 Push Setup ==="
echo ""

# ── 1. Verify push_server starts cleanly ──────────────────────────────────────
echo "[1/5] Verifying push_server.py..."
cd "$PROJ"
python3 push_server.py &
PUSH_PID=$!
sleep 2
if curl -sf "http://127.0.0.1:$PUSH_PORT/vapid-public-key" > /dev/null; then
    echo "      ✅ Push server responding"
else
    echo "      ❌ Push server failed to start. Check logs/push_server.log"
    kill $PUSH_PID 2>/dev/null
    exit 1
fi
kill $PUSH_PID 2>/dev/null
sleep 1

# ── 2. Cloudflare Tunnel ───────────────────────────────────────────────────────
echo "[2/5] Setting up Cloudflare Tunnel..."

TUNNEL_NAME="ptox11-push"
TUNNEL_CRED_DIR="$HOME/.cloudflared"
TUNNEL_CONFIG="$TUNNEL_CRED_DIR/config.yml"

# Login if needed
if [ ! -f "$TUNNEL_CRED_DIR/cert.pem" ]; then
    echo "      Opening browser for Cloudflare login..."
    cloudflared tunnel login
fi

# Create tunnel (idempotent — skips if already exists)
if cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
    echo "      Tunnel '$TUNNEL_NAME' already exists — reusing"
    TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_NAME" | awk '{print $1}')
else
    echo "      Creating tunnel '$TUNNEL_NAME'..."
    TUNNEL_ID=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1 | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    echo "      Tunnel ID: $TUNNEL_ID"
fi

# Write tunnel config
mkdir -p "$TUNNEL_CRED_DIR"
cat > "$TUNNEL_CONFIG" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $TUNNEL_CRED_DIR/$TUNNEL_ID.json
ingress:
  - service: http://127.0.0.1:$PUSH_PORT
EOF
echo "      Config written: $TUNNEL_CONFIG"

# Get tunnel URL (trycloudflare or named domain)
TUNNEL_URL="https://$TUNNEL_NAME.cfargotunnel.com"
echo "      Tunnel URL: $TUNNEL_URL"

# ── 3. Patch notify.html with tunnel URL ──────────────────────────────────────
echo "[3/5] Patching docs/notify.html with tunnel URL..."
sed -i '' "s|__PUSH_SERVER_URL__|$TUNNEL_URL|g" "$PROJ/docs/notify.html"
echo "      ✅ Patched"

# ── 4. Install launchd plists ─────────────────────────────────────────────────
echo "[4/5] Installing launchd services..."
mkdir -p "$PLIST_DIR"

# push_server.py plist
cat > "$PLIST_DIR/com.ptox11.pushserver.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>           <string>com.ptox11.pushserver</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$PROJ/push_server.py</string>
  </array>
  <key>WorkingDirectory</key> <string>$PROJ</string>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>StandardOutPath</key>  <string>$PROJ/logs/push_server_launchd.log</string>
  <key>StandardErrorPath</key><string>$PROJ/logs/push_server_launchd.log</string>
</dict>
</plist>
EOF

# cloudflared plist
cat > "$PLIST_DIR/com.ptox11.cloudflared.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>           <string>com.ptox11.cloudflared</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/cloudflared</string>
    <string>tunnel</string>
    <string>--config</string>
    <string>$TUNNEL_CONFIG</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>StandardOutPath</key>  <string>$PROJ/logs/cloudflared.log</string>
  <key>StandardErrorPath</key><string>$PROJ/logs/cloudflared.log</string>
</dict>
</plist>
EOF

launchctl load "$PLIST_DIR/com.ptox11.pushserver.plist" 2>/dev/null || true
launchctl load "$PLIST_DIR/com.ptox11.cloudflared.plist" 2>/dev/null || true
echo "      ✅ Services loaded"

# ── 5. Summary ────────────────────────────────────────────────────────────────
echo ""
echo "[5/5] Done!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Push server:     http://127.0.0.1:$PUSH_PORT"
echo "  Tunnel URL:      $TUNNEL_URL"
echo "  Subscribe page:  https://ocx11.github.io/PTOX11/notify.html"
echo ""
echo "  Share this URL with anyone who wants notifications:"
echo "  → https://ocx11.github.io/PTOX11/notify.html"
echo ""
echo "  Test a push:"
echo "  python3 -c \""
echo "  import urllib.request, json"
echo "  d = json.dumps({'title':'Test','body':'PTOX11 push working','url':''}).encode()"
echo "  r = urllib.request.Request('http://127.0.0.1:$PUSH_PORT/send-push',d,{'Content-Type':'application/json'},'POST')"
echo "  print(urllib.request.urlopen(r).read().decode())"
echo "  \""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

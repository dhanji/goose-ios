#!/bin/bash

# Function to clean up processes
cleanup() {
    echo ""
    echo "Shutting down services..."
    if [ ! -z "$GOOSED_PID" ]; then
        kill $GOOSED_PID 2>/dev/null
    fi
    if [ ! -z "$CLOUDFLARED_PID" ]; then
        kill $CLOUDFLARED_PID 2>/dev/null
    fi
    killall goosed 2>/dev/null
    killall cloudflared 2>/dev/null
    rm -f tunnel_url.txt 2>/dev/null
    echo "Cleanup complete"
    exit 0
}

# Set up trap for script exit (including Ctrl+C)
trap cleanup EXIT INT TERM

# Install required tools if not already installed
if ! command -v cloudflared &> /dev/null; then
    echo "Installing cloudflared..."
    brew install cloudflared
fi

if ! command -v qrencode &> /dev/null; then
    echo "Installing qrencode..."
    brew install qrencode
fi

# Generate a secure random key (32 characters)
GOOSE_SECRET=$(openssl rand -base64 24)

# Export environment variables for goosed
export GOOSE_SERVER__SECRET_KEY="$GOOSE_SECRET"
export GOOSE_PORT=62996
export GOOSE_STANDALONE_MODE="true"

# Kill any existing goosed processes
killall goosed 2>/dev/null

# Kill any existing cloudflared processes
killall cloudflared 2>/dev/null

# Wait a moment for processes to terminate
sleep 1

# Start goosed in the background
goosed agent &
GOOSED_PID=$!

echo "goosed started with PID: $GOOSED_PID"

# Wait a moment for goosed to start
sleep 2

# Start cloudflared and capture its output
echo "Starting cloudflared tunnel..."
rm -f tunnel_url.txt
(cloudflared tunnel --url http://localhost:62996 2>&1 | while read line; do
    echo "$line"
    if echo "$line" | grep -q "trycloudflare.com"; then
        echo "$line" | grep -o 'https://[^[:space:]]*\.trycloudflare\.com' > tunnel_url.txt
    fi
done) &
CLOUDFLARED_PID=$!

# Wait for the URL file to appear (up to 15 seconds)
max_attempts=15
attempt=0
while [ ! -s tunnel_url.txt ] && [ $attempt -lt $max_attempts ]; do
    sleep 1
    echo "Waiting for tunnel URL... ($(($attempt + 1))/$max_attempts)"
    attempt=$((attempt + 1))
done

if [ -s tunnel_url.txt ]; then
    # Get base URL and remove any newlines
    CONNECT_URL="$(cat tunnel_url.txt | tr -d '\n'):443"
    
    # Create JSON-style data for QR code and URL scheme
    CONFIG_DATA="{\"url\":\"$CONNECT_URL\",\"secret\":\"$GOOSE_SECRET\"}"
    
    # URL encode the config data
    URL_ENCODED_CONFIG=$(echo -n "$CONFIG_DATA" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=''))")
    APP_URL="goosechat://configure?data=$URL_ENCODED_CONFIG"
    
    # Create QR code for the app URL
    echo $APP_URL | qrencode -o tunnel_qr.png -s 10
    
    # Display the QR code if running in terminal
    if [ -t 1 ]; then
        echo $APP_URL | qrencode -t ANSI
    fi
    
    # Open the QR code image
    open tunnel_qr.png
    
    # Print connection details after QR code
    echo ""
    echo "========== CONNECTION DETAILS =========="
    echo "URL:    $CONNECT_URL"
    echo "Secret: $GOOSE_SECRET"
    echo "App URL: $APP_URL"
    echo "====================================="
    echo ""
    echo "Scan the QR code with your camera to configure the app"
    echo ""
    echo "Press Ctrl+C to stop all services"
else
    echo "❌ Failed to get tunnel URL after $max_attempts seconds"
    cleanup
    exit 1
fi

# Wait forever (until Ctrl+C)
wait

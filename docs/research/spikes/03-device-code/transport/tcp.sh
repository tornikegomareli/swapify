#!/bin/zsh
# TCP measurements between the Mac and the spike app, all in one launch of `serve`. Needs the phone
# unlocked at launch; the app keeps the screen awake while it is frontmost.
#   inbound:  the Mac connects to the app's listener on [::]:7777.
#   outbound: the Mac asks the app (DIAL) to connect to a listener on the Mac.
# Each over the CoreDevice tunnel and over Wi-Fi. The tunnel gets new addresses when it is
# re-created, so they are read before every run.
cd "${0:A:h}/.."
UDID=${UDID:-00008160-000A51191083400A}
BID=dev.swapify.spike.device
LOGS=build/logs
WIFI_DEVICE=${WIFI_DEVICE:-172.20.10.1}  # the phone, as the Mac sees it on Wi-Fi
WIFI_MAC=${WIFI_MAC:-$(ipconfig getifaddr en0)}

tunnel() {  # prints "<device address> <mac address>"
    local dev=$(xcrun devicectl device info details --device $UDID 2>&1 | sed -n 's/.*Tunnel IP Address: //p')
    local mac=$(ifconfig | grep -o "inet6 ${dev%::1}::[0-9a-f]*" | awk '{print $2}' | grep -v '::1$' | head -1)
    echo $dev $mac
}

xcrun devicectl device process launch --device $UDID --console --terminate-existing $BID -- --test serve \
    > $LOGS/serve.app.log 2>&1 &
SERVE=$!
until grep -q "listening on\|RESULT\|ERROR" $LOGS/serve.app.log 2>/dev/null; do sleep 0.5; done
grep -E "ERROR|RESULT|Locked" $LOGS/serve.app.log && exit 1

for run in 1 2 3; do
    read DEV MAC <<< "$(tunnel)"
    echo "== run $run (tunnel: phone $DEV, Mac $MAC; Wi-Fi: phone $WIFI_DEVICE, Mac $WIFI_MAC)"
    python3 -I transport/measure.py tcp "$DEV" 7777 "inbound, tunnel"
    python3 -I transport/measure.py tcp "$WIFI_DEVICE" 7777 "inbound, Wi-Fi"
    python3 -I transport/measure.py tcp-dial "$DEV" 7777 "$MAC" 7778 "outbound, tunnel"
    python3 -I transport/measure.py tcp-dial "$WIFI_DEVICE" 7777 "$WIFI_MAC" 7779 "outbound, Wi-Fi"
done
echo "heartbeats: $(grep -c heartbeat $LOGS/serve.app.log), accepted: $(grep -c accepted $LOGS/serve.app.log)"
grep -E "DIAL" $LOGS/serve.app.log
kill $SERVE 2>/dev/null

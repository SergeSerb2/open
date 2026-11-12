#!/bin/bash
# Open remote build: bring up one NativeLink worker on a boat.dev sandbox.
# Args: SCHED_SSH_HOST (IPv6 of the scheduler) SCHED_HOSTKEY_LINE WORKER_NAME SLOTS
# Needs /opt/e3/nativelink-worker.json5, /opt/e3/setup-node.sh, ~/.ssh/e3_worker (key the
# scheduler allows for port forwarding only).
set -euo pipefail
sched=$1 hostkey=$2 name=$3 slots=${4:-8}
bash /opt/e3/setup-node.sh >/dev/null
printf '%s %s\n' "$sched" "$hostkey" > ~/.ssh/e3_known_hosts
sudo mkdir -p /opt/e3/data /opt/e3/work /opt/e3/log && sudo chown user:user /opt/e3/log
cat > /opt/e3/tunnel-loop.sh <<TL
#!/bin/bash
while true; do
  ssh -N -i \$HOME/.ssh/e3_worker -o IdentitiesOnly=yes -o UserKnownHostsFile=\$HOME/.ssh/e3_known_hosts \
    -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    -L 127.0.0.1:50051:127.0.0.1:50051 -L 127.0.0.1:50061:127.0.0.1:50061 user@$sched
  sleep 2
done
TL
chmod +x /opt/e3/tunnel-loop.sh
setsid nohup /opt/e3/tunnel-loop.sh > /opt/e3/log/tunnel.log 2>&1 < /dev/null &
for i in $(seq 1 30); do (echo > /dev/tcp/127.0.0.1/50061) 2>/dev/null && break; sleep 1; done
sudo env E3_SCHED=127.0.0.1 E3_NAME="$name" E3_SLOTS="$slots" setsid nohup /opt/e3/nativelink /opt/e3/nativelink-worker.json5 > /opt/e3/log/worker.log 2>&1 < /dev/null &
sleep 3
sed 's/\x1b\[[0-9;]*m//g' /opt/e3/log/worker.log | grep -E "registered|ERROR" | tail -2

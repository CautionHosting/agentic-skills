#!/usr/bin/env bash
# Some nested/LXC Linux VMs ship dockerd on the systemd cgroup driver, which is
# broken there — every `docker run` dies with "Inappropriate ioctl for device".
# Switch dockerd to cgroupfs and restart it by hand (systemd often can't manage it).
# No-op if the driver is already cgroupfs. Needs sudo.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

if docker info --format '{{.CgroupDriver}}' 2>/dev/null | grep -qx cgroupfs; then
  log "cgroup driver already cgroupfs — nothing to do"
  exit 0
fi

log "switching dockerd to the cgroupfs driver"
echo '{ "exec-opts": ["native.cgroupdriver=cgroupfs"] }' | sudo tee /etc/docker/daemon.json >/dev/null
sudo pkill -9 -x dockerd 2>/dev/null || true
sleep 2
sudo rm -f /var/run/docker.pid
sudo setsid dockerd >/tmp/dockerd.log 2>&1 < /dev/null &
sleep 5

docker info --format 'cgroupDriver={{.CgroupDriver}}' | grep -qx 'cgroupDriver=cgroupfs' \
  || die "dockerd did not come up with cgroupfs — see /tmp/dockerd.log"
docker run --rm hello-world >/dev/null 2>&1 || die "container smoke test failed — see /tmp/dockerd.log"
log "dockerd on cgroupfs and running containers"

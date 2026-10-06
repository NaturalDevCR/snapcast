#!/usr/bin/env bash
set -euo pipefail
: "${BETA_TAG:?Set BETA_TAG to a beta release tag}"
: "${DISTRO:?Set DISTRO to bookworm or trixie}"
[[ "$BETA_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-naturaldevcr\.beta\.[0-9]+$ ]] || exit 2
[[ "$DISTRO" == bookworm || "$DISTRO" == trixie ]] || exit 2
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends build-essential cmake pkg-config git fakeroot debhelper python3 unzip wget libboost-dev libasound2-dev libsoxr-dev libvorbis-dev libflac-dev libopus-dev libavahi-client-dev libexpat1-dev libssl-dev libpulse-dev libasio-dev
ln -s extras/package/debian debian
version="${BETA_TAG#v}"
version="${version/-/~}-1"
cat > debian/changelog <<CHANGELOG
snapcast ($version) unstable; urgency=medium

  * NaturalDevCR beta: TCP recovery, UDP/RTP sources and ALSA stream recovery.

 -- NaturalDevCR <snapcast-beta@users.noreply.github.com>  $(date -R)
CHANGELOG
wget -q https://github.com/snapcast/snapweb/releases/download/v0.9.2/snapweb.zip
unzip -q snapweb.zip -d snapweb
fakeroot make -f debian/rules CMAKEFLAGS="-DCMAKE_BUILD_TYPE=Release -DREVISION=$(git rev-parse --short HEAD) -DBUILD_WITH_PULSE=ON -DSNAPWEB_DIR=$PWD/snapweb" binary
mkdir -p out
for file in ../snapclient_*.deb ../snapserver_*.deb; do
  name="$(basename "$file" .deb)"
  cp "$file" "out/${name}_${DISTRO}.deb"
done
(cd out && sha256sum *.deb > SHA256SUMS)

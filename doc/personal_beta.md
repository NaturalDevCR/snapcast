# NaturalDevCR beta packages

The `codex/personal-beta` branch combines TCP recovery (#1481), UDP/RTP sources
(#1502), and ALSA stream recovery (#1556). It is maintained separately from the
upstream pull requests.

To publish a beta, commit and push the tested changes, then push a tag:

```sh
git tag v0.35.0-naturaldevcr.beta.4
git push origin v0.35.0-naturaldevcr.beta.4
```

The Personal beta workflow runs regression tests and builds Debian Bookworm and
Trixie packages for amd64, arm64 and armhf. ARM64 builds use hosted ARM runners;
armhf builds use QEMU. A prerelease is published only after all jobs succeed.
Snapclient includes ALSA and PulseAudio. Asset names end in the architecture and
Debian codename, and the release includes `SHA256SUMS`.

Debian package versions use `~naturaldevcr.beta.N`, which sorts below the same
upstream version. Snapcast Manager's installation channel picker uses the release
tag, supports a pinned beta or the latest compatible beta, and preserves
configuration when switching back to official packages.

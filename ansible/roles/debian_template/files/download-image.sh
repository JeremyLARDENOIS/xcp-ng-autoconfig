#!/usr/bin/env bash
# Download and verify the official RAW image without modifying it.
set -euo pipefail
work=$1
mkdir -p "$work"
cd "$work"
build=20250811-2201
image="debian-13-generic-amd64-${build}.raw"
base="https://cloud.debian.org/images/cloud/trixie/${build}"
if [[ -f image.sha512 ]]; then
    sha512sum --check image.sha512
else
    curl --fail --location --retry 3 "$base/SHA512SUMS" -o SHA512SUMS.download
    expected=$(awk -v name="$image" '$2 == name || $2 == "*"name {print $1}' SHA512SUMS.download)
    [[ "$expected" =~ ^[[:xdigit:]]{128}$ ]] || { echo 'Missing or ambiguous image checksum' >&2; exit 1; }
    curl --fail --location --retry 3 "$base/$image" -o "$image.download"
    printf '%s  %s\n' "$expected" "$image.download" | sha512sum --check -
    mv "$image.download" "$image"
    printf '%s  %s\n' "$expected" "$image" > image.sha512.tmp
    mv image.sha512.tmp image.sha512
    echo 'CHANGED: official RAW image downloaded'
fi
sha256sum "$image" > template.sha256.tmp
mv template.sha256.tmp template.sha256

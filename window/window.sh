#!/bin/bash
# The public half of the window's run on GitHub's Macs: fetches age, opens
# bundle.tar.age with the repository's AGE_KEY secret and runs the run.sh
# inside it. Everything it learns goes into out/results.tar.age, encrypted to
# the same key, so the public log and artifact show nothing of the project.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W=$HOME/zfwindow
mkdir -p "$W/age" "$W/b" "$HERE/out"
ARCH=$(uname -m)
[ "$ARCH" = x86_64 ] && A=amd64 || A=arm64
curl -sSL "https://github.com/FiloSottile/age/releases/download/v1.2.1/age-v1.2.1-darwin-$A.tar.gz" \
    | tar -xz -C "$W/age" --strip-components 1
printf '%s\n' "$AGE_KEY" > "$W/key.txt"
"$W/age/age" -d -i "$W/key.txt" "$HERE/bundle.tar.age" | tar -x -C "$W/b"
rm -f "$W/key.txt"
mkdir -p "$W/results"
bash "$W/b/run.sh" "$W" > "$W/results/report.txt" 2>&1
echo "run.sh exited $?"
tar -C "$W/results" -cf - . | "$W/age/age" -r "$(cat "$W/b/recipient.txt")" \
    > "$HERE/out/results.tar.age"
ls -l "$HERE/out"

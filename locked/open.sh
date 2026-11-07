#!/bin/bash
# The public half of a locked run: fetches age, opens bundle.tar.age with the repository's
# AGE_KEY secret and runs the run.sh inside it. All that it learns goes into
# out/results.tar.age, locked again, so the public log and artifact show nothing.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W=$HOME/locked
mkdir -p "$W/age" "$W/b" "$W/results" "$HERE/out"
if [ "$(uname -m)" = x86_64 ]; then
  A=amd64; SUM=424e1d64438a730626540b2e01e98d132a64214442ca9465b3e82336d12e633e
else
  A=arm64; SUM=cf79875bd5970dc2dac60c87fa50cee1ff1f9a41b0eb273f65e174aff37c367a
fi
curl -sSL -o "$W/age.tar.gz" \
    "https://github.com/FiloSottile/age/releases/download/v1.2.1/age-v1.2.1-darwin-$A.tar.gz"
[ "$(shasum -a 256 "$W/age.tar.gz" | cut -d' ' -f1)" = "$SUM" ] || { echo "age: bad sum"; exit 1; }
tar -xz -C "$W/age" --strip-components 1 -f "$W/age.tar.gz"
printf '%s\n' "$AGE_KEY" > "$W/key.txt"
unset AGE_KEY
"$W/age/age" -d -i "$W/key.txt" "$HERE/bundle.tar.age" | tar -x -C "$W/b"
rm -f "${W:?}/key.txt"
/usr/bin/perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 4800 \
    bash "$W/b/run.sh" "$W" > "$W/results/report.txt" 2>&1
echo "exit $?"
COPYFILE_DISABLE=1 tar -C "$W/results" -cf - . \
    | "$W/age/age" -r "$(cat "$W/b/recipient.txt")" > "$HERE/out/results.tar.age"

#!/bin/bash
# What a modern macOS answers to the questions zipfreeze's 10.13 measurements
# left open. Run by GitHub Actions on each of its Mac machines, with
#   PYNEW, PY38  the newest Python and 3.8, either one empty when the runner
#                has none for this processor;
#   AGE_KEY      the age identity that opens bundle.tar.age.
# and its output piped into results/report.txt by the workflow.
# Every check prints EXPECT (what a person's Mac is predicted to answer, from
# 10.13 or from what Apple has said changed since), WATCH FOR (the answer that
# would matter), and then the commands it ran with their output and exit code.
# Nothing here judges: the report is read by a person, and a CI machine is not
# a person's Mac, which the MACHINE section is there to show.
# bash 3.2, which is /bin/bash on every macOS.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
R=$HERE/results
W=$HOME/zfprobe
mkdir -p "$R" "$W"

section() { printf '\n\n######## %s\n' "$1"; }
check() { printf '\n==== %s\n' "$1"; }
expect() { printf 'EXPECT: %s\n' "$1"; }
watch() { printf 'WATCH FOR: %s\n' "$1"; }

# Runs a command for at most $1 seconds, printing it, its output and its exit
# code. A command killed at the limit exits 142.
limit() {
  local s=$1; shift
  printf '$ %s\n' "$*"
  /usr/bin/perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$s" "$@"
  printf '[exit %s]\n' "$?"
}
run() { limit 120 "$@"; }

# Names spelled in ASCII, so a decomposed accent and a byte stand out.
ASCII='import os, sys
for line in sys.stdin.buffer:
    print(ascii(os.fsdecode(line.rstrip(b"\n")))[1:-1])'
HELPER=${PYNEW:-/usr/bin/python3}
asciify() { "$HELPER" -c "$ASCII"; }

PYS=""
[ -n "${PY38:-}" ] && PYS="$PY38"
[ -n "${PYNEW:-}" ] && PYS="$PYS $PYNEW"

# --------------------------------------------------------------------------
section "UNPACKING"
ARCH=$(uname -m)
# v1.2.1 is the build RUNBOOK names; v1.3.2 the newest at the time of writing.
AGES="v1.2.1-amd64 v1.2.1-arm64 v1.3.2-amd64 v1.3.2-arm64"
for va in $AGES; do
  mkdir -p "$W/age-$va"
  curl -sSL "https://github.com/FiloSottile/age/releases/download/${va%-*}/age-${va%-*}-darwin-${va#*-}.tar.gz" \
    | tar -xz -C "$W/age-$va" --strip-components 1
done
NATIVE=$W/age-v1.2.1-arm64/age
[ "$ARCH" = x86_64 ] && NATIVE=$W/age-v1.2.1-amd64/age
printf '%s\n' "$AGE_KEY" > "$W/key.txt"
mkdir -p "$W/b"
"$NATIVE" -d -i "$W/key.txt" "$HERE/bundle.tar.age" | tar -x -C "$W/b"
rm -f "$W/key.txt"
Z=$W/b/zipfreeze.py
FACTS=$W/b/platform-facts.py
FIX=$W/b/fixture
ls "$W/b" "$FIX"
for p in $PYS; do printf 'python: %s = %s\n' "$p" "$("$p" -c 'import sys; print(sys.version.split()[0])')"; done
[ -n "${PY38:-}" ] || echo "python: NO 3.8 on this runner"
[ -n "${PYNEW:-}" ] || echo "python: NO newest Python on this runner"

# --------------------------------------------------------------------------
section "MACHINE: what this CI machine is, as against a person's Mac"

check "M1 system and processor"
expect "the macOS the job asked for; arm64 on an Apple processor, x86_64 on Intel"
run sw_vers
run uname -m
run sysctl -n machdep.cpu.brand_string
run sysctl -n sysctl.proc_translated
echo "ImageOS=${ImageOS:-} ImageVersion=${ImageVersion:-} RUNNER_ARCH=${RUNNER_ARCH:-}"

check "M2 System Integrity Protection and Gatekeeper"
expect "on a person's Mac: 'System Integrity Protection status: enabled' and 'assessments enabled'"
watch "either one disabled, which makes the Gatekeeper check in 4.6 say nothing about a person's Mac"
run csrutil status
run spctl --status

check "M3 who is at the desktop, and does Finder answer a script"
expect "a person's Mac: the user owns /dev/console and Finder answers"
watch "no console user, or osascript refused or killed at 30 s: then the Finder steps in section 2 did nothing"
run stat -f %Su /dev/console
run who
limit 30 osascript -e 'tell application "Finder" to get name of startup disk'

check "M4 Full Disk Access already granted (it would hide section 1)"
expect "a person's Mac: Terminal holds no Full Disk Access unless the user gave it; the system TCC.db is unreadable without it"
watch "the system TCC.db readable, or rows naming kTCCServiceSystemPolicyAllFiles for bash, sh, sshd or the runner: then section 1's reads succeed only because CI granted them"
run sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, service, auth_value FROM access ORDER BY service, client;"
run sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, service, auth_value FROM access ORDER BY service, client;"
run ls "$HOME/Library/Mail"

check "M5 Rosetta, the home's filesystem, the user, sudo"
expect "a new Apple-processor Mac has no Rosetta until something asks for it; the home is APFS; sudo asks for a password"
watch "Rosetta present on an Apple runner: then 4.6's amd64 age running there does not show what a new Mac does"
run arch -x86_64 /usr/bin/true
run pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto
run diskutil info /
run id
run sudo -n true

check "M6 which programs the PATH finds first"
expect "/usr/bin for each of sqlite3, unzip, shasum, rm, touch, python3 on a person's Mac; no sha256sum, age, python"
watch "a Homebrew copy first: section 4 calls /usr/bin by full path for that reason"
for c in sqlite3 unzip shasum sha256sum rm touch python3 python age; do
  printf '%s: ' "$c"; type -a "$c" 2>&1 | tr '\n' ';'; echo
done

check "M7 screencapture"
expect "a picture of the desktop, unless macOS asks for Screen Recording permission"
watch "exit non-zero or a blank picture: no window pictures can be taken on this runner"
run screencapture -x "$R/screen.png"
ls -l "$R/screen.png" 2>&1

# --------------------------------------------------------------------------
section "1. FOLDERS macOS PROTECTS INSIDE THE HOME"
cat <<'EOF'
EXPECT on a person's Mac: the first read of each folder below puts a question on
screen (or, for Mail, Safari and Messages, is refused outright without Full Disk
Access); after Don't Allow a read fails with `Operation not permitted` (errno 1,
EPERM), not 10.13's `Permission denied`, and `plan` prints its unreadable-directory
WARNING and exits 1.
WATCH FOR: the exact text `plan` prints for such a folder (SPECIFICATION.md and
RUNBOOK.md quote messages); a read that succeeds, which on CI more likely means
the runner was granted access (M4) than that the folder is open; and above all
whether the Photos library's originals can be read from a shell at all.
A folder that does not exist on this runner is reported as such: that is "not
measured", not "open".
EOF

check "1.0 making the folders that are not there"
for d in Desktop Documents Downloads; do
  run sh -c "printf 'proba\n' > \"\$HOME/$d/zf-proba.txt\""
done
limit 40 open -g -a Photos
sleep 20
limit 10 osascript -e 'tell application "Photos" to quit'
pkill -x Photos 2>/dev/null

plan_of() {   # plan_of PYTHON DIR [extra plan options]; leaves $W/p.json
  local py=$1 dir=$2; shift 2
  rm -f "$W/p.json" "$W/p.sqlite"
  limit "${PLAN_LIMIT:-900}" "$py" "$Z" --index "$W/p.sqlite" plan "$dir" --label t --plan "$W/p.json" "$@" \
    > "$W/plan.txt" 2>&1
  grep -v -E '^(source|label|sources|bytes|archives|archive size|plan written)' "$W/plan.txt" \
    | sed '$d' | head -n 80
  tail -n 1 "$W/plan.txt"
}

protected_folders() {   # protected_folders TAG
  for d in "Library/Mail" "Library/Safari" "Library/Messages" Desktop Documents Downloads \
           "Pictures/Photos Library.photoslibrary" "Library/Mobile Documents" \
           "Library/Containers" "Library/Group Containers" ".Trash"; do
    check "$1 ~/$d"
    if [ ! -e "$HOME/$d" ]; then echo "NOT PRESENT on this runner: not measured"; continue; fi
    limit 60 ls -la "$HOME/$d"
    for p in $PYS; do plan_of "$p" "$HOME/$d"; done
  done

  check "$1.P the Photos library's originals, read from a shell"
  watch "Operation not permitted on originals/ is the answer that matters for a photo backup"
  if [ -e "$HOME/Pictures/Photos Library.photoslibrary" ]; then
    run ls -la "$HOME/Pictures/Photos Library.photoslibrary"
    run ls -la "$HOME/Pictures/Photos Library.photoslibrary/originals"
  else
    echo "NOT PRESENT on this runner: not measured"
  fi

  check "$1.H plan of the home as a whole"
  expect "a WARNING per protected folder above, exit 1"
  watch "which folders are named, and the text of each line"
  {
    echo "[archive]"
    for d in Desktop Documents Downloads Movies Music Pictures Public Library .Trash; do
      [ -d "$HOME/$d" ] && echo "/$d/"
    done
    echo "[exclude]"
    echo "/Library/Caches/"
    echo "/Library/Developer/"
    echo "/Library/Android/"
  } > "$W/home.conf"
  echo "config (the runner's toolchains are left out, being tens of GB):"
  cat "$W/home.conf"
  for p in $PYS; do plan_of "$p" "$HOME" --config "$W/home.conf"; done
}

protected_folders 1

section "1R. THE SAME FOLDERS WITH FULL DISK ACCESS TAKEN AWAY"
cat <<'EOF'
The runner gives /bin/bash and the runner's own programs Full Disk Access (M4),
which answers section 1 for them. With System Integrity Protection off (M2),
root can delete those grants from both TCC databases and restart tccd, the
daemon that answers them. Then the same reads, from a process nobody granted.
EXPECT: what section 1's EXPECT says of a person's Mac. With nobody at the
screen to answer a question, a read may wait for an answer: each is cut off.
WATCH FOR: whether the grants were really gone (the counts printed), whether a
read now fails and with which errno and text, a read that hangs (exit 142),
and screen-1R.png, a picture taken while ~/Desktop was being read: the
question macOS puts on screen, if it puts one there.
EOF
check "1R.0 taking the grants away"
for db in "/Library/Application Support/com.apple.TCC/TCC.db" \
          "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
  run sudo -n sqlite3 "$db" "DELETE FROM access WHERE service LIKE 'kTCCServiceSystemPolicy%' OR service = 'kTCCServicePhotos'; SELECT changes();"
done
run sudo -n killall tccd
run killall tccd
sleep 5
run sudo -n sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, service, auth_value FROM access WHERE service LIKE 'kTCCServiceSystemPolicy%';"
check "1R.S a picture while ~/Desktop is read"
/usr/bin/perl -e 'alarm 60; exec @ARGV' ls -la "$HOME/Desktop" > "$W/desk.txt" 2>&1 &
sleep 10
run screencapture -x "$R/screen-1R.png"
wait
echo "[ls of Desktop exit $?]"; cat "$W/desk.txt"
PLAN_LIMIT=300 protected_folders 1R

# --------------------------------------------------------------------------
section "2. THE TOP OF A DRIVE, AND 3. WHAT EACH FILESYSTEM DOES WITH NAMES"
cat <<'EOF'
Five 2 GB sparse disk images: exFAT, FAT32, HFS+, APFS, case-sensitive APFS
(and case-sensitive HFS+ for section 3 only).
EXPECT (2) on each of the first four, after Finder copies a file, sends one to
the Trash and opens a window, TextEdit edits and saves a file, and Spotlight is
switched on: macOS leaves .Spotlight-V100, .fseventsd, .Trashes and perhaps
.TemporaryItems and .DocumentRevisions-V100 at the top; `plan` of the top lists
each as `macOS's own folder`, prints no WARNING and exits 0; ._ files beside the
files on exFAT and FAT32 are archived.
WATCH FOR (2): a folder at the top that is not one of those five, `plan` exiting
1, a WARNING, and whether macOS asked before a program read the image (from
10.15 it asks before reading a removable volume; whether an image is one is the
question). On 10.13 TextEdit stopped at a dialog on exFAT and FAT32.
EOF

IMG=$W/images
mkdir -p "$IMG"
bounded() {   # a GUI step: at most 25 s, output dropped, never fails
  /usr/bin/perl -e 'alarm 25; exec @ARGV' "$@" >/dev/null 2>&1
  echo "[$1 ... exit $?]"
}
check "2.0 making and attaching the images (no sudo)"
for spec in "ZFEX ExFAT" "ZFFAT MS-DOS FAT32" "ZFHFS HFS+J" "ZFAPFS APFS" \
            "ZFAPFSX Case-sensitive APFS" "ZFHFSX Case-sensitive HFS+"; do
  set -- $spec; n=$1; shift
  run hdiutil create -quiet -type SPARSE -size 2g -fs "$*" -volname "$n" "$IMG/$n"
  run hdiutil attach -quiet "$IMG/$n.sparseimage"
done
for n in ZFEX ZFFAT ZFHFS ZFAPFS; do
  v=/Volumes/$n
  printf 'eleje\n' > "$v/jegyzet.txt"
  printf 'kuka\n' > "$v/torlendo.txt"
  printf 'masolni\n' > "$IMG/src-$n.txt"
  bounded osascript -e "tell application \"Finder\" to duplicate POSIX file \"$IMG/src-$n.txt\" to POSIX file \"$v\""
  bounded osascript -e "tell application \"Finder\" to delete POSIX file \"$v/torlendo.txt\""
  bounded osascript -e "tell application \"Finder\" to open POSIX file \"$v\""
  bounded osascript -e 'tell application "TextEdit"' \
    -e "set d to open POSIX file \"$v/jegyzet.txt\"" \
    -e 'set text of d to "masodik valtozat"' -e 'save d' -e 'close d' -e 'end tell'
  run mdutil -i on "$v"
  run sudo -n mdutil -i on "$v"
done
sleep 90
bounded osascript -e 'tell application "Finder" to close every window'
pkill -x TextEdit 2>/dev/null

for n in ZFEX ZFFAT ZFHFS ZFAPFS ZFAPFSX; do
  v=/Volumes/$n
  check "2 top of $n: $(diskutil info "$v" | sed -n 's/.*Personality: *//p')"
  run ls -la "$v"
  xattr "$v/jegyzet.txt" 2>/dev/null | sed 's/^/   attribute of jegyzet.txt: /'
  for p in $PYS; do
    plan_of "$p" "$v"
    "$p" -c '
import collections, json, sys
plan = json.load(open(sys.argv[1]))
tops = collections.Counter(rel.split("/")[0] for archive in plan["archives"]
                           for rel, _, _ in archive["files"])
for top, count in sorted(tops.items()):
    print("   planned", count, ascii(top))' "$W/p.json" 2>&1
    rm -f "$W/p.json" "$W/p.sqlite"
  done
done

cat <<'EOF'


EXPECT (3): tools/platform-facts.py's answers on each image, as 10.13 gave them
in docs/platform-facts-macos-*.txt (they are diffed against those files after
the run, not here).
WATCH FOR (3): macOS 15 is reported to have moved exFAT and FAT32 out of the
kernel into programs of their own, so on those two: a composed or decomposed
name not kept as written, a name that is not valid UTF-8 accepted instead of
refused with EILSEQ (errno 92), different stand-in characters for names Windows
refuses, a different pair of names held as one file, a different time
resolution, and what os.path.ismount says of the top.
EOF
for n in ZFEX ZFFAT ZFHFS ZFHFSX ZFAPFS ZFAPFSX HOME; do
  v=/Volumes/$n; [ $n = HOME ] && v=$HOME
  for p in $PYS; do
    tag=py$("$p" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    mkdir -p "$v/facts-$tag"
    limit 600 "$p" "$FACTS" "$v/facts-$tag" > "$R/facts-$n-$tag.txt" 2>&1
    echo "facts $n $tag: exit $? -> results/facts-$n-$tag.txt"
    rm -rf "$v/facts-$tag"
  done
done

check "2b restoring the fixture onto each image, with zipfreeze"
cat <<'EOF'
EXPECT: extract of each archive exits 0 and verify-source finds the tree as
archived, except where a filesystem keeps two names as one: there the second
lands under a ZFMARKER name and extract exits 1, as plan warned. On FAT32, 10.13
refused a name that is not valid UTF-8 and extract landed it under its %XX
member name.
WATCH FOR: on FAT32, Twins/k\xe9p.jpg and Twins/k%E9p.jpg, which macOS 15's
FAT32 now writes as one name: does one file's bytes overwrite the other's, does
extract say so, and what verify-source says. On exFAT the eszett pair.
EOF
for n in ZFEX ZFFAT ZFHFS ZFAPFS ZFAPFSX; do
  for p in $PYS; do
    tag=py$("$p" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    d=/Volumes/$n/restored-$tag
    check "2b $n $tag"
    for a in "$FIX"/archives/*.zip; do
      limit 120 "$p" "$Z" --index "$FIX/index.sqlite" extract "$a" --dest "$d"
    done
    limit 120 "$p" "$Z" --index "$FIX/index.sqlite" verify-source --source "$d"
    (cd "$d" 2>/dev/null && find . -type f | LC_ALL=C sort) | asciify
    for f in "$d"/Twins/*; do
      printf '%s holds: ' "$(basename "$f" | asciify)"; cat "$f"
    done
  done
done

check "2.9 detaching"
for image in $(hdiutil info | sed -n "s|^image-path *: *\($IMG/.*\)|\1|p"); do
  for d in $(hdiutil info | awk -v img="$image" '
      $1 == "image-path" { on = ($3 == img) }
      on && $1 ~ /^\/dev\/disk[0-9]+$/ { print substr($1, 10) }' | sort -rn); do
    hdiutil detach -quiet "disk$d" || hdiutil detach -quiet -force "disk$d"
  done
done
hdiutil info | grep -q "$IMG" && echo "AN IMAGE IS STILL ATTACHED"
rm -rf "$IMG"

# --------------------------------------------------------------------------
section "4. RESTORING WITHOUT ZIPFREEZE (RUNBOOK section 4, its Mac part)"
cat <<'EOF'
Every program is called by its full path in /usr/bin, because the runner puts
Homebrew's first (M6). The fixture is a real archive and restore kit, built by
zipfreeze on Linux from a tree holding Photos/2011/Wien/DSC_00007.jpg and
Wien/nap/este.jpg, Photos/2011/Budapest/hid.jpg, a composed Fényképek.jpg, a
decomposed Árvíztűrő tükörfúrógép.txt, Grüße & Küsse.jpg, Docs/Έγγραφα.txt,
Docs/awkward<TAB>tab.jpg and Photos/2003/Nyaral\xe1s/k\xe9p.jpg (not valid UTF-8).
EOF
K=$FIX/kit
IDX=$K/index.sqlite
A=$FIX/archives
cd "$W"

check "4.1 sqlite3: version, -line, how it compares a name stored as bytes"
expect "-line prints 'name = value', one column per line (10.13); the CAST LIKE query finds the byte name as one X'...' row; = X'...' finds it too"
watch "the bare LIKE finding nothing while CAST finds it (Debian's behaviour), or CAST finding nothing (the recipe would be wrong on a Mac)"
run /usr/bin/sqlite3 -version
run /usr/bin/sqlite3 -line "$IDX" "SELECT key, value FROM meta WHERE key IN ('label', 'schema_version');"
run /usr/bin/sqlite3 "$IDX" "PRAGMA compile_options;"
run /usr/bin/sqlite3 "$IDX" "SELECT quote(path), member FROM file WHERE CAST(path AS TEXT) LIKE 'Photos/2003/%';"
run /usr/bin/sqlite3 "$IDX" "SELECT quote(path), member FROM file WHERE path LIKE 'Photos/2003/%';"
run /usr/bin/sqlite3 -line "$IDX" "SELECT a.name, f.member, f.data_offset, f.compress_size
  FROM file f JOIN archive a ON a.id = f.archive_id
  WHERE f.path = X'50686F746F732F323030332F4E796172616CE1732F6BE9702E6A7067';"

check "4.2 shasum reading the kit's SHA256SUMS"
expect "Photos.part001.zip: OK, exit 0"
mkdir -p "$W/s4" && cd "$W/s4" && cp "$A"/*.zip .
grep Photos.part001.zip "$K/reference/SHA256SUMS" | /usr/bin/shasum -a 256 -c -
echo "[exit $?]"

check "4.3 unzip: still shipped, its listing of accented names, -^, and **"
expect "unzip -l prints every name byte from 0x80 to 0x9F as '?' (so Έγγραφα, Grüße & Küsse and the decomposed Árvíztűrő list wrongly); the files it writes keep their names, composed or decomposed as archived; without -^ the tab is dropped from the name, with -^ it is kept; 'Photos/2011/Wien/**' extracts both DSC_00007.jpg and nap/este.jpg and not Budapest"
watch "the listing now right (the 0x80-0x9F claim is out of date), a written name changed in its form, ** not crossing into nap/"
run /usr/bin/unzip -v
/usr/bin/unzip -l Photos.part001.zip | asciify
/usr/bin/unzip -l Docs.part001.zip | asciify
run /usr/bin/unzip -t Photos.part001.zip
mkdir w && (cd w && /usr/bin/unzip -q ../Photos.part001.zip 'Photos/2011/Wien/**'; echo "[unzip Wien/** exit $?]"; find . -type f | asciify)
mkdir all && (cd all && /usr/bin/unzip -q ../Photos.part001.zip; echo "[unzip all exit $?]"; find . -type f | asciify)
mkdir t1 && (cd t1 && /usr/bin/unzip -q ../Docs.part001.zip; echo "[unzip Docs exit $?]"; find . -type f | asciify)
mkdir t2 && (cd t2 && /usr/bin/unzip -q -^ ../Docs.part001.zip; echo "[unzip -^ Docs exit $?]"; find . -type f | asciify)

check "4.4 the byte-name recipe's last line"
expect "on APFS the printf name cannot be made: 'Illegal byte sequence', and the file stays under its member name"
(cd all && /usr/bin/unzip -p ../Photos.part001.zip 'Photos/2003/Nyaral%E1s/k%E9p.jpg' > "$(printf 'k\xe9p.jpg')"; echo "[exit $?]"; ls | asciify)

check "4.5 rm -P"
expect "RUNBOOK says rm -P overwrites key.txt before deleting it"
watch "man rm saying -P has no effect (on APFS, or at all), which makes RUNBOOK's line a false promise"
man rm 2>/dev/null | col -b | grep -n -A6 -E '^ *-P'
printf 'titok\n' > key.txt; run /bin/rm -P key.txt

check "4.6 age: amd64 against arm64, and Gatekeeper's quarantine mark"
expect "on Apple Silicon without Rosetta the darwin-amd64 build cannot start ('Bad CPU type in executable'); darwin-arm64 runs; a quarantined unsigned binary started from a shell may be refused or killed by Gatekeeper"
watch "the amd64 build running on arm64 (then Rosetta is installed, M5), and the exit and message with the quarantine mark set"
for a in $AGES; do
  b=$W/age-$a/age
  run file "$b"
  run "$b" --version
  run codesign -dv "$b"
  for flag in 0081 0083; do
    rm -rf "$W/q-$a"; cp -R "$W/age-$a" "$W/q-$a"
    xattr -w com.apple.quarantine "$flag;$(printf %x "$(date +%s)");Safari;" "$W/q-$a/age"
    run xattr -l "$W/q-$a/age"
    run spctl -a -vv -t execute "$W/q-$a/age"
    limit 30 "$W/q-$a/age" --version
  done
done
KG=$(dirname "$NATIVE")/age-keygen
"$KG" -o k.txt 2>/dev/null
printf 'proba\n' | "$NATIVE" -r "$("$KG" -y k.txt)" | "$NATIVE" -d -i k.txt
echo "[age round trip exit $?]"; rm -f k.txt

check "4.7 python3 and python"
expect "on a person's Mac without Apple's developer tools, /usr/bin/python3 is a stand-in that offers to install them; /usr/bin/python is gone since 12.3"
watch "the runner has the developer tools (xcode-select -p answers), so its python3 being real says nothing about a person's Mac"
run xcode-select -p
run /usr/bin/python3 --version
run ls -l /usr/bin/python /usr/bin/python3

check "4.8 touch"
expect "TZ=UTC touch -t 201106140931.07 sets 2011-06-14 09:31:07 UTC; RUNBOOK says a Mac's touch has no -d"
watch "touch -d accepted: then the Linux line works on a Mac too"
TZ=UTC /usr/bin/touch -t 201106140931.07 f1; echo "[touch -t exit $?]"; TZ=UTC stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' f1
/usr/bin/touch -d 2011-06-14T09:31:07Z f2; echo "[touch -d exit $?]"; TZ=UTC stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' f2 2>&1

check "4.9 age's amd64 build with Rosetta removed (Apple processor only)"
expect "'Bad CPU type in executable', exit 86, which is what a new Apple-processor Mac answers before Rosetta is installed"
watch "anything else, or Rosetta not going away (then this says nothing)"
if [ "$ARCH" = arm64 ]; then
  run sudo -n launchctl bootout system/com.apple.oahd
  run sudo -n rm -rf /Library/Apple/usr/libexec/oah
  run sudo -n pkgutil --forget com.apple.pkg.RosettaUpdateAuto
  run arch -x86_64 /usr/bin/true
  run "$W/age-v1.2.1-amd64/age" --version
else
  echo "an Intel machine: nothing to remove"
fi

cd "$HERE"
rm -rf "$W"
section "DONE"

#!/usr/bin/env bash
set -euo pipefail

# The payload alone is inert: this fixture pins the initiation contract of
# vencord-git (docs/NOTE.md 2026-09-23) against scratch trees. Discovery goes
# through the standard XDG_CONFIG_HOME seam, so the real home is never
# touched and no extra test knob exists.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
inject="$root/packages/git/vencord-git/vencord-inject"
desktop="$root/packages/git/vencord-git/vencord-discord-desktop"

fail() {
    printf 'vencord-inject fixture: %s\n' "$1" >&2
    exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/vencord-inject.XXXXXX")
trap 'rm -rf "$work"' EXIT

cfg="$work/config"
res_new="$cfg/discord/app-1.0.159/resources"
res_old="$cfg/discord/app-1.0.9/resources"
res_canary="$cfg/discordcanary/app-0.0.312/resources"
mkdir -p "$res_new" "$res_old" "$res_canary"
printf 'PRISTINE-ASAR-ORIGINAL-BYTES' >"$res_new/app.asar"
printf 'PRISTINE-OLD-VERSION' >"$res_old/app.asar"
printf 'PRISTINE-CANARY' >"$res_canary/app.asar"

vi() {
    XDG_CONFIG_HOME="$cfg" "$inject" "$@"
}

embedded_patcher() {
    python3 - "$1" <<'PYEOF'
import json, struct, sys
data = open(sys.argv[1], "rb").read()
_, hsz, _, hss = struct.unpack_from("<4I", data)
hdr = json.loads(data[16:16 + hss])
e = hdr["files"]["index.js"]
off = 8 + hsz + int(e["offset"])
sys.stdout.write(data[off:off + int(e["size"])].decode()[len('require("'):-2])
PYEOF
}

# --- inject: newest app-* per channel, every channel, oldest left alone ------
vi inject >/dev/null || fail "inject returned non-zero on pristine trees"
test -f "$res_new/_app.asar" || fail "pristine app.asar was not renamed"
cmp -s <(printf 'PRISTINE-ASAR-ORIGINAL-BYTES') "$res_new/_app.asar" ||
    fail "_app.asar is not the byte-identical original"
cmp -s <(printf 'PRISTINE-OLD-VERSION') "$res_old/app.asar" ||
    fail "an older app-* version was patched; only the newest per channel may be"
test -f "$res_canary/_app.asar" ||
    fail "second channel (discordcanary) was not discovered"
vi status >/dev/null || fail "status is not green after injecting every channel"

got=$(embedded_patcher "$res_new/app.asar")
[ "$got" = /usr/lib/vencord/patcher.js ] ||
    fail "shim embeds '$got', expected the pacman-owned patcher"

# --- idempotence: a second run changes nothing -------------------------------
before=$(sha256sum "$res_new/app.asar" "$res_new/_app.asar")
vi inject >/dev/null || fail "second inject returned non-zero"
[ "$before" = "$(sha256sum "$res_new/app.asar" "$res_new/_app.asar")" ] ||
    fail "inject is not idempotent"

# --- adoption: a foreign (official-installer) shim is repointed in place -----
printf 'OFFICIAL-SHIM-POINTING-ELSEWHERE' >"$res_new/app.asar"
keep=$(sha256sum "$res_new/_app.asar")
vi inject >/dev/null || fail "adopting an already-patched tree failed"
[ "$keep" = "$(sha256sum "$res_new/_app.asar")" ] ||
    fail "adoption rewrote _app.asar"
if cmp -s <(printf 'OFFICIAL-SHIM-POINTING-ELSEWHERE') "$res_new/app.asar"; then
    fail "foreign shim was not rewritten"
fi
vi status >/dev/null || fail "adoption did not repoint at /usr/lib/vencord"

# --- interrupted state: backup present, shim missing -------------------------
rm "$res_new/app.asar"
vi inject >/dev/null || fail "repair of a missing shim failed"
vi status >/dev/null || fail "status is red after repairing a missing shim"

# --- uninject restores the pristine original byte-for-byte -------------------
vi uninject >/dev/null || fail "uninject returned non-zero"
cmp -s <(printf 'PRISTINE-ASAR-ORIGINAL-BYTES') "$res_new/app.asar" ||
    fail "uninject did not restore the pristine app.asar"
test ! -e "$res_new/_app.asar" || fail "_app.asar left behind after uninject"
if vi status >/dev/null 2>&1; then
    fail "status reports injected after uninject"
fi

# --- fresh bootstrap: no channel at all --------------------------------------
mkdir -p "$work/empty"
XDG_CONFIG_HOME="$work/empty" "$inject" inject >/dev/null ||
    fail "inject must no-op (rc=0) when no channel exists yet"
if XDG_CONFIG_HOME="$work/empty" "$inject" status >/dev/null 2>&1; then
    fail "status is green without any channel"
fi

# --- desktop Exec wrap/restore, idempotent both ways -------------------------
desk="$work/discord.desktop"
cat >"$desk" <<'EOF'
[Desktop Entry]
Name=Discord
Exec=/usr/bin/discord --url -- %u
MimeType=x-scheme-handler/discord;
EOF
cp "$desk" "$work/orig.desktop"
"$desktop" wrap "$desk"
grep -q '^Exec=/usr/bin/discord-vencord --url -- %u$' "$desk" ||
    fail "wrap did not redirect the stock Exec line"
"$desktop" wrap "$desk"
[ "$(grep -c 'discord-vencord' "$desk" || true)" = 1 ] ||
    fail "wrap is not idempotent — the Exec line double-wrapped"
"$desktop" restore "$desk"
cmp -s "$desk" "$work/orig.desktop" ||
    fail "restore did not return the original Exec line"
"$desktop" restore "$desk"
cmp -s "$desk" "$work/orig.desktop" || fail "restore is not idempotent"
"$desktop" wrap "$work/absent.desktop" ||
    fail "wrap of an absent file must exit 0 (discord not installed yet)"

# --- wrapper: injects first, then execs Discord with args intact -------------
wrapdir="$work/wrap"
mkdir -p "$wrapdir"
printf '#!/bin/sh\n: >"%s/inject-called"\n' "$work" >"$wrapdir/inject-stub"
printf '#!/bin/sh\nprintf "DISCORD:%%s\\n" "$*" >"%s/discord-args"\nexit 7\n' \
    "$work" >"$wrapdir/discord-stub"
chmod +x "$wrapdir/inject-stub" "$wrapdir/discord-stub"
# Fixture-local copy only: retarget the wrapper's absolute paths at stubs.
sed -e "s|/usr/bin/vencord-inject|$wrapdir/inject-stub|" \
    -e "s|/usr/bin/discord|$wrapdir/discord-stub|" \
    "$root/packages/git/vencord-git/discord-vencord" >"$wrapdir/wrapper"
rc=0
sh "$wrapdir/wrapper" --url -- '%u' || rc=$?
[ "$rc" = 7 ] || fail "wrapper does not exec Discord (exit $rc, expected 7)"
test -f "$work/inject-called" || fail "wrapper did not run vencord-inject first"
[ "$(cat "$work/discord-args")" = 'DISCORD:--url -- %u' ] ||
    fail "wrapper mangled the launcher arguments: $(cat "$work/discord-args")"

printf 'vencord-inject fixture: PASS\n'

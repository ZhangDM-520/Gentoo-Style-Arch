#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-mkinitcpio-nvpcr.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/install"
cat >"$fixture/install/systemd" <<'EOF'
build() {
    # Include nvpcr files
    for nvpcr in /usr/lib/nvpcr/*.nvpcr; do
        add_file "$nvpcr"
    done
}
EOF
cat >"$fixture/install/sd-encrypt" <<'EOF'
build() {
    # add mkswap for creating swap space on the fly (see 'swap' in crypttab(5))
    add_binary 'mkswap'

    # add NVPCR definition files
    map add_file /usr/lib/nvpcr/*.nvpcr

    if [[ -f /etc/crypttab.initramfs ]]; then
        add_file '/etc/crypttab.initramfs' '/etc/crypttab' 600
    fi
}
EOF

patch -d "$fixture" -Np1 -i \
    "$root/packages/stable/mkinitcpio/0001-skip-missing-optional-nvpcr-files.patch" \
    >/dev/null

cat >"$fixture/run-hooks.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

add_file() {
    test -f "$1"
}

add_binary() {
    :
}

systemd_hook="$1"
sd_encrypt_hook="$2"
source "$systemd_hook"
build
source "$sd_encrypt_hook"
build
EOF
chmod +x "$fixture/run-hooks.sh"

"$fixture/run-hooks.sh" \
    "$fixture/install/systemd" \
    "$fixture/install/sd-encrypt"

printf 'mkinitcpio optional NVPCR fixture: PASS\n'

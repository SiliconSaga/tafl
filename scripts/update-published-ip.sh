#!/usr/bin/env bash
# update-published-ip.sh — repoint the game fleet's published address.
#
# The fleet is fronted by ONE DNS A record (play.terasology.org). Every hosted
# server shares it and they are told apart by port, which is why KubicValheim's
# base runs externalTrafficPolicy: Cluster — any node's external IP serves the
# NodePorts. When the node behind the published address is recycled, the servers
# are fine and the NAME is broken.
#
# Repointing means changing TWO things that must not disagree:
#
#   1. the Namecheap A record
#   2. the address written into kustomize/fleet/published-ip.yaml
#
# The alert in that file never resolves DNS — it only checks whether the address
# written there still appears among node ExternalIP metrics. So if the two drift
# apart, the alert sits GREEN while the fleet is unreachable by name. This script
# does both halves together for exactly that reason; `--dns-only` and
# `--manifest-only` exist for recovery, not for routine use.
#
# THE DANGEROUS PART. Namecheap has no per-record update call. The only write is
# namecheap.domains.dns.setHosts, which is DECLARATIVE FOR THE WHOLE DOMAIN — it
# replaces every record with whatever you send. terasology.org carries records
# for the forum, the wiki, GitHub Pages verification and SPF, so a write that
# forgets one deletes it, and the API returns success. That is why the rebuild
# lives in scripts/namecheap_hosts.py behind real tests rather than in shell
# string handling, and why this script refuses to write on anything unexpected.
#
# Do NOT use nordri's scripts/update-dns-namecheap.sh here. It sends only `@`
# and `*`, so against this domain it would delete everything else.
#
# Usage:
#   scripts/update-published-ip.sh <new-ip>              # dry run, prints the plan
#   scripts/update-published-ip.sh <new-ip> --apply      # actually writes
#   scripts/update-published-ip.sh --show                # current state, no changes
#
# Options:
#   --apply           Perform the write. Without it nothing is changed anywhere.
#   --dns-only        Skip the manifest edit.
#   --manifest-only   Skip the Namecheap call.
#   --domain <d>      Default: terasology.org
#   --record <name>   Default: play
#   --manifest <path> Default: kustomize/fleet/published-ip.yaml
#
# Credentials come from yggdrasil's root .env (NAMECHEAP_API_USER /
# NAMECHEAP_API_KEY), which `ws` sources before dispatch — so
# `ws exec tafl scripts/update-published-ip.sh …` just works. Namecheap also
# allowlists by CALLING IP: the machine running this must be on the API
# allowlist at https://ap.www.namecheap.com/settings/tools/apiaccess/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DOMAIN="terasology.org"
RECORD="play"
RECORD_TYPE="A"
MANIFEST="$REPO_ROOT/kustomize/fleet/published-ip.yaml"
APPLY=false
DO_DNS=true
DO_MANIFEST=true
SHOW_ONLY=false
NEW_IP=""

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)         APPLY=true; shift ;;
        --dns-only)      DO_MANIFEST=false; shift ;;
        --manifest-only) DO_DNS=false; shift ;;
        --show)          SHOW_ONLY=true; shift ;;
        --domain)        DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
        --record)        RECORD="${2:?--record needs a value}"; shift 2 ;;
        --manifest)      MANIFEST="${2:?--manifest needs a value}"; shift 2 ;;
        -h|--help)       sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//;$d'; exit 0 ;;
        -*)              die "unknown option '$1' (see --help)" ;;
        *)
            [[ -n "$NEW_IP" ]] && die "unexpected extra argument '$1'"
            NEW_IP="$1"; shift ;;
    esac
done

# --- Interpreter resolution -------------------------------------------------
# Not cosmetic. On Windows `python3` is usually the Microsoft Store alias stub,
# which prints an install advert and exits 49 — so a bare `python3` shebang
# fails on the very machines this repo is driven from. Probe by RUNNING each
# candidate rather than trusting its name or its --version output: the stub
# answers some invocations and not others.
PYTHON=""
for candidate in "${TAFL_PYTHON:-}" python3 python py /c/Python311/python.exe; do
    [[ -z "$candidate" ]] && continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    if [[ "$("$candidate" -c 'print("probe-ok")' 2>/dev/null)" == "probe-ok" ]]; then
        PYTHON="$candidate"
        break
    fi
done
[[ -n "$PYTHON" ]] || die "no working python3 found (tried python3, python, py). Set TAFL_PYTHON to an interpreter."

HOSTS_PY="$SCRIPT_DIR/namecheap_hosts.py"
[[ -f "$HOSTS_PY" ]] || die "missing $HOSTS_PY"

# --- Read current manifest address ------------------------------------------
# The manifest is the record of what we BELIEVE is published; the A record is
# what is actually published. Reading both is how we detect they have drifted.
manifest_address() {
    [[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
    grep -oE 'address="[0-9]{1,3}(\.[0-9]{1,3}){3}"' "$MANIFEST" \
        | head -1 | sed 's/.*"\(.*\)"/\1/'
}

TLD="${DOMAIN##*.}"
SLD="${DOMAIN%.*}"
API_BASE="https://api.namecheap.com/xml.response"

require_credentials() {
    [[ -n "${NAMECHEAP_API_USER:-}" ]] || die "NAMECHEAP_API_USER not set (expected from yggdrasil .env — run via 'ws exec tafl …')"
    [[ -n "${NAMECHEAP_API_KEY:-}" ]]  || die "NAMECHEAP_API_KEY not set (expected from yggdrasil .env — run via 'ws exec tafl …')"
}

CLIENT_IP=""
detect_client_ip() {
    [[ -n "$CLIENT_IP" ]] && return
    CLIENT_IP="$(curl -sf --max-time 10 https://api.ipify.org)" \
        || die "could not determine this machine's public IP (needed as Namecheap's ClientIp)"
}

# Snapshots are the undo. Written BEFORE any write, named by timestamp, and
# kept even on success — a diffable record of the domain as it was. Deliberately
# NOT under /tmp: the whole point is to still be there when someone realises
# hours later that a record went missing, and /tmp does not survive a reboot.
SNAPSHOT_DIR="${TAFL_SNAPSHOT_DIR:-$REPO_ROOT/.dns-snapshots}"
get_hosts() {
    local out="$1"
    require_credentials
    detect_client_ip
    curl -sf --max-time 20 -o "$out" --get "$API_BASE" \
        --data-urlencode "ApiUser=${NAMECHEAP_API_USER}" \
        --data-urlencode "ApiKey=${NAMECHEAP_API_KEY}" \
        --data-urlencode "UserName=${NAMECHEAP_API_USER}" \
        --data-urlencode "ClientIp=${CLIENT_IP}" \
        --data-urlencode "Command=namecheap.domains.dns.getHosts" \
        --data-urlencode "SLD=${SLD}" \
        --data-urlencode "TLD=${TLD}" \
        || die "getHosts request failed. If this is an auth error, check that $CLIENT_IP is allowlisted at https://ap.www.namecheap.com/settings/tools/apiaccess/"
}

current_record_address() {
    local xml="$1"
    "$PYTHON" - "$xml" "$RECORD" "$RECORD_TYPE" <<'PY'
import sys, os
sys.path.insert(0, os.environ["TAFL_SCRIPT_DIR"])
import namecheap_hosts as nh
with open(sys.argv[1], encoding="utf-8") as fh:
    parsed = nh.parse_get_hosts(fh.read())
for r in parsed["records"]:
    if r["HostName"] == sys.argv[2] and r["RecordType"].upper() == sys.argv[3].upper():
        print(r["Address"])
        break
PY
}
export TAFL_SCRIPT_DIR="$SCRIPT_DIR"

# --- Show current state ------------------------------------------------------
mkdir -p "$SNAPSHOT_DIR"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

if [[ "$SHOW_ONLY" == true ]]; then
    echo "domain:    $DOMAIN"

    dns_addr=""
    if [[ "$DO_DNS" == true ]]; then
        snap="$SNAPSHOT_DIR/${DOMAIN}-${STAMP}-show.xml"
        get_hosts "$snap"
        dns_addr="$(current_record_address "$snap")"
        echo "record:    ${RECORD}.${DOMAIN} ($RECORD_TYPE) = ${dns_addr:-<not found>}"
        echo "snapshot:  $snap"
    fi

    if [[ "$DO_MANIFEST" == true ]]; then
        man_addr="$(manifest_address)"
        echo "manifest:  $MANIFEST = ${man_addr:-<none>}"
    fi

    # The sync verdict is only meaningful when the record being inspected is the
    # one the manifest describes. Comparing some other domain's record against
    # this manifest would report DRIFTED for two values that were never supposed
    # to match — a false alarm in the tool whose whole job is detecting drift.
    if [[ "$DO_DNS" == true && "$DO_MANIFEST" == true ]]; then
        if [[ "$DOMAIN" == "terasology.org" && "$RECORD" == "play" ]]; then
            if [[ "$dns_addr" == "$man_addr" ]]; then
                echo "state:     IN SYNC"
            else
                echo "state:     ⚠ DRIFTED — the alert rule is watching an address nobody is sent to"
            fi
        else
            echo "state:     n/a — ${RECORD}.${DOMAIN} is not the record this manifest tracks"
        fi
    fi
    exit 0
fi

[[ -n "$NEW_IP" ]] || die "no new IP given. Usage: $0 <new-ip> [--apply]  (or --show)"
[[ "$NEW_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "'$NEW_IP' is not an IPv4 address"

echo "Repointing the published game-fleet address to $NEW_IP"
echo "  domain:   $DOMAIN (record ${RECORD}, type ${RECORD_TYPE})"
echo "  manifest: $MANIFEST"
[[ "$APPLY" == true ]] || echo "  MODE:     DRY RUN — nothing will be changed. Add --apply to write."
echo

# --- Half 1: DNS -------------------------------------------------------------
if [[ "$DO_DNS" == true ]]; then
    SNAPSHOT="$SNAPSHOT_DIR/${DOMAIN}-${STAMP}-before.xml"
    echo "== Namecheap =="
    get_hosts "$SNAPSHOT"
    echo "snapshot (undo reference): $SNAPSHOT"

    # The python side validates and refuses on anything unexpected: non-OK
    # status, zero records, a missing/ambiguous target, inactive records it
    # cannot faithfully resend, or a record count that changed mid-substitution.
    PARAM_FILE="$SNAPSHOT_DIR/${DOMAIN}-${STAMP}-params.txt"
    "$PYTHON" "$HOSTS_PY" build-set-hosts "$SNAPSHOT" \
        --name "$RECORD" --type "$RECORD_TYPE" --address "$NEW_IP" >"$PARAM_FILE"

    # Independent re-count in shell. The python module already asserts this, but
    # this is the value about to be sent to a destructive API, so it gets checked
    # on the way out as well as on the way in.
    read_count=$(grep -c '<host ' "$SNAPSHOT")
    write_count=$(grep -cE '^HostName[0-9]+=' "$PARAM_FILE")
    [[ "$read_count" -gt 0 ]] || die "read zero records from $SNAPSHOT — refusing to write"
    [[ "$read_count" -eq "$write_count" ]] \
        || die "record count mismatch: read $read_count, about to write $write_count. REFUSING — this would delete records."
    echo "record count: $read_count read, $write_count to write — match"

    if [[ "$APPLY" == true ]]; then
        curl_args=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && curl_args+=(--data-urlencode "$line")
        done <"$PARAM_FILE"

        require_credentials
        detect_client_ip
        RESULT="$SNAPSHOT_DIR/${DOMAIN}-${STAMP}-setresult.xml"
        curl -sf --max-time 30 -o "$RESULT" --get "$API_BASE" \
            --data-urlencode "ApiUser=${NAMECHEAP_API_USER}" \
            --data-urlencode "ApiKey=${NAMECHEAP_API_KEY}" \
            --data-urlencode "UserName=${NAMECHEAP_API_USER}" \
            --data-urlencode "ClientIp=${CLIENT_IP}" \
            --data-urlencode "Command=namecheap.domains.dns.setHosts" \
            --data-urlencode "SLD=${SLD}" \
            --data-urlencode "TLD=${TLD}" \
            "${curl_args[@]}" \
            || die "setHosts request failed. Domain may be unchanged; verify with --show and restore from $SNAPSHOT if needed."

        grep -q 'IsSuccess="true"' "$RESULT" \
            || die "setHosts did not report success. Response: $RESULT — verify with --show, restore from $SNAPSHOT if needed."
        echo "setHosts: success"

        # Read it back. A success flag is a claim; the record set is the fact.
        VERIFY="$SNAPSHOT_DIR/${DOMAIN}-${STAMP}-after.xml"
        get_hosts "$VERIFY"
        after_count=$(grep -c '<host ' "$VERIFY")
        after_addr="$(current_record_address "$VERIFY")"
        [[ "$after_count" -eq "$read_count" ]] \
            || echo "⚠ WARNING: record count is now $after_count, was $read_count. Compare $SNAPSHOT and $VERIFY." >&2
        [[ "$after_addr" == "$NEW_IP" ]] \
            || die "verification failed: ${RECORD}.${DOMAIN} reads '$after_addr', expected '$NEW_IP'"
        echo "verified: ${RECORD}.${DOMAIN} = $after_addr ($after_count records intact)"
    else
        echo "(dry run) would send $write_count records; full parameter set in $PARAM_FILE"
    fi
    echo
fi

# --- Half 2: the alert manifest ---------------------------------------------
if [[ "$DO_MANIFEST" == true ]]; then
    echo "== Alert manifest =="
    OLD_ADDR="$(manifest_address)"
    [[ -n "$OLD_ADDR" ]] || die "could not find an address=\"…\" in $MANIFEST"

    if [[ "$OLD_ADDR" == "$NEW_IP" ]]; then
        echo "$MANIFEST already reads $NEW_IP — nothing to do"
    else
        # -oF, not -c: `grep -c` counts matching LINES, and the description
        # line carries the address twice. Reporting a count lower than what the
        # rewrite actually changes is exactly the kind of small inaccuracy that
        # makes an operator distrust the tool at the worst moment.
        occurrences=$(grep -oF "$OLD_ADDR" "$MANIFEST" | wc -l | tr -d ' ')
        echo "replacing $OLD_ADDR -> $NEW_IP ($occurrences occurrence(s))"
        # The address appears in the expression AND in the human-facing summary
        # and description. Updating only the expression leaves the page telling
        # an operator to look for an address that is no longer involved.
        if [[ "$APPLY" == true ]]; then
            "$PYTHON" - "$MANIFEST" "$OLD_ADDR" "$NEW_IP" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
count = text.count(old)
if count == 0:
    sys.exit(f"ERROR: {old} not present in {path}")
with open(path, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(text.replace(old, new))
print(f"rewrote {count} occurrence(s) in {path}")
PY
            echo "NOTE: left as an uncommitted working-tree change on purpose."
            echo "      Review it, then land it through the normal CR + GitOps path."
        else
            echo "(dry run) would rewrite $occurrences occurrence(s)"
        fi
    fi
    echo
fi

# --- Closing note on propagation --------------------------------------------
if [[ "$APPLY" == true && "$DO_DNS" == true ]]; then
    echo "Namecheap now serves $NEW_IP. Resolvers that already cached the old"
    echo "answer keep it until the record's TTL expires (~30 min at TTL 1799),"
    echo "so an immediate lookup returning the OLD address is expected, not a"
    echo "failure. Players already connected are unaffected — Valheim clients"
    echo "resolve the name per session."
fi

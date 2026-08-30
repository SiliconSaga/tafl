#!/usr/bin/env python3
"""Parse a Namecheap getHosts response and rebuild it as setHosts parameters.

This exists because `namecheap.domains.dns.setHosts` is **declarative for the
whole domain**: it replaces the entire record set with whatever you send. There
is no per-record update call. So changing one A record means reading every
record, substituting one address, and writing them all back — and any record
dropped between the read and the write is deleted from DNS.

That makes the parse/rebuild the dangerous part of the operation, which is why
it lives here in a real XML parser with real tests rather than in shell
string-handling. `update-published-ip.sh` orchestrates; this module is the part
that must not lose a record.

Fields `setHosts` accepts per record are HostName, RecordType, Address, MXPref
and TTL. Everything else getHosts returns (HostId, AssociatedAppTitle,
FriendlyName, IsActive, IsDDNSEnabled) has no setHosts equivalent and cannot be
round-tripped — see `assert_round_trippable` for how that is handled rather than
ignored.
"""

import argparse
import json
import sys
import xml.etree.ElementTree as ET

NS = {"nc": "http://api.namecheap.com/xml.response"}

# Namecheap accepts these per-record on setHosts. Anything else getHosts
# returns is read-only metadata we cannot resend.
SET_HOSTS_FIELDS = ("HostName", "RecordType", "Address", "MXPref", "TTL")


class NamecheapError(Exception):
    """A response we refuse to act on. Always fatal — never fall through."""


def parse_get_hosts(xml_text):
    """Parse a getHosts response into {'domain', 'email_type', 'records'}.

    Raises NamecheapError on anything we cannot vouch for. The bar is
    deliberately high: every early return here is a case where continuing would
    mean sending an incomplete record set to a declarative API, i.e. deleting
    DNS records. An exception is always cheaper than that.
    """
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as exc:
        raise NamecheapError(f"response is not well-formed XML: {exc}") from exc

    status = root.get("Status")
    if status != "OK":
        errors = [e.text or "" for e in root.findall(".//nc:Errors/nc:Error", NS)]
        detail = "; ".join(x for x in errors if x) or "no error detail returned"
        raise NamecheapError(f"API reported Status={status!r}: {detail}")

    result = root.find(".//nc:DomainDNSGetHostsResult", NS)
    if result is None:
        raise NamecheapError(
            "no DomainDNSGetHostsResult element — this is not a getHosts response"
        )

    # EmailType is domain-level, not per-record, and setHosts takes it as a
    # parameter. Omitting it on the write resets the domain's email routing —
    # terasology.org runs EmailType=FWD (forwarding), so dropping this silently
    # breaks mail while every DNS record still looks correct.
    email_type = result.get("EmailType")
    if not email_type:
        raise NamecheapError(
            "result carries no EmailType; refusing to guess, because sending the "
            "wrong value would silently change the domain's email routing"
        )

    hosts = result.findall("nc:host", NS)
    if not hosts:
        # An empty parse is precisely how you would wipe a domain: zero records
        # in means zero records written back out.
        raise NamecheapError(
            "getHosts returned zero host records — refusing to continue, because "
            "writing an empty set back would delete every record on the domain"
        )

    records = []
    for host in hosts:
        records.append(
            {
                "HostName": host.get("Name"),
                "RecordType": host.get("Type"),
                "Address": host.get("Address"),
                "MXPref": host.get("MXPref"),
                "TTL": host.get("TTL"),
                # Retained for validation only; never sent.
                "_IsActive": host.get("IsActive"),
                "_AssociatedAppTitle": host.get("AssociatedAppTitle"),
            }
        )

    for index, record in enumerate(records, start=1):
        missing = [f for f in SET_HOSTS_FIELDS if not record.get(f)]
        if missing:
            raise NamecheapError(
                f"record {index} ({record.get('HostName')!r} "
                f"{record.get('RecordType')!r}) is missing {', '.join(missing)} — "
                "cannot rebuild it faithfully"
            )

    return {
        "domain": result.get("Domain"),
        "email_type": email_type,
        "records": records,
    }


def assert_round_trippable(parsed):
    """Refuse cases where a setHosts write would lose state we cannot resend.

    setHosts has no IsActive parameter, so a disabled record would come back
    enabled — a silent, invisible change to live DNS. We would rather stop and
    make a human decide than quietly re-enable something switched off on
    purpose.
    """
    # A missing IsActive is rejected rather than assumed active. setHosts cannot
    # restore a disabled record, so "we did not see the flag" and "the flag said
    # active" are different claims, and only the second one justifies a rewrite.
    unknown = [
        f"{r['HostName']} {r['RecordType']}"
        for r in parsed["records"]
        if r.get("_IsActive") is None
    ]
    if unknown:
        raise NamecheapError(
            "these records did not report IsActive, so a rewrite cannot be shown "
            "to preserve their state: " + ", ".join(unknown)
        )

    disabled = [
        f"{r['HostName']} {r['RecordType']}"
        for r in parsed["records"]
        if r["_IsActive"].lower() != "true"
    ]
    if disabled:
        raise NamecheapError(
            "these records are inactive and setHosts has no IsActive parameter, "
            "so rewriting the domain would silently re-enable them: "
            + ", ".join(disabled)
        )


def replace_address(parsed, name, record_type, new_address):
    """Substitute one record's Address, matching on name+type.

    Requires exactly one match. Zero matches means the caller is wrong about
    what exists (and creating the record instead would be a different, unasked-
    for operation). Multiple matches — terasology.org has two `www` A records —
    means the request is ambiguous, and picking one arbitrarily would silently
    do half the job.
    """
    matches = [
        i
        for i, r in enumerate(parsed["records"])
        if r["HostName"] == name and r["RecordType"].upper() == record_type.upper()
    ]

    if not matches:
        available = sorted({f"{r['HostName']} {r['RecordType']}" for r in parsed["records"]})
        raise NamecheapError(
            f"no {record_type} record named {name!r} on {parsed['domain']}. "
            "This script updates existing records only, it never creates them. "
            f"Present: {', '.join(available)}"
        )

    if len(matches) > 1:
        raise NamecheapError(
            f"{len(matches)} {record_type} records named {name!r} — ambiguous. "
            "Updating one and not the others would leave the name resolving to a "
            "mix of old and new addresses."
        )

    index = matches[0]
    old_address = parsed["records"][index]["Address"]
    parsed["records"][index]["Address"] = new_address
    return old_address


def to_set_hosts_params(parsed):
    """Emit setHosts parameters as `key=value` lines, one per line.

    The caller feeds each line to `curl --data-urlencode`, which is what keeps
    an SPF record's spaces, `=`, `:` and `~` intact. Values are NOT encoded
    here — encoding twice is its own corruption.
    """
    lines = [f"EmailType={parsed['email_type']}"]
    for index, record in enumerate(parsed["records"], start=1):
        for field in SET_HOSTS_FIELDS:
            lines.append(f"{field}{index}={record[field]}")
    return lines


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_parse = sub.add_parser("parse", help="parse getHosts XML to JSON")
    p_parse.add_argument("xml_file")

    p_build = sub.add_parser(
        "build-set-hosts",
        help="parse getHosts XML, replace one address, emit setHosts params",
    )
    p_build.add_argument("xml_file")
    p_build.add_argument("--name", required=True, help="record name, e.g. 'play'")
    p_build.add_argument("--type", default="A", help="record type (default: A)")
    p_build.add_argument("--address", required=True, help="new address")

    args = parser.parse_args(argv)

    with open(args.xml_file, "r", encoding="utf-8") as handle:
        xml_text = handle.read()

    try:
        parsed = parse_get_hosts(xml_text)

        if args.command == "parse":
            json.dump(parsed, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0

        assert_round_trippable(parsed)
        count_before = len(parsed["records"])
        old = replace_address(parsed, args.name, args.type, args.address)
        count_after = len(parsed["records"])

        # The count invariant is the last line of defence: whatever the
        # substitution did, it must not have changed how many records exist.
        if count_before != count_after:
            raise NamecheapError(
                f"record count changed during substitution ({count_before} -> "
                f"{count_after}) — refusing to write"
            )

        # Diagnostics go to stderr so stdout stays a clean parameter stream.
        print(
            f"{args.name} {args.type}: {old} -> {args.address} "
            f"({count_after} records, EmailType={parsed['email_type']})",
            file=sys.stderr,
        )
        for line in to_set_hosts_params(parsed):
            print(line)
        return 0

    except NamecheapError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

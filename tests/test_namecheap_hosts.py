#!/usr/bin/env python3
"""Tests for the getHosts -> setHosts rebuild.

The property under test is preservation. `setHosts` replaces a domain's entire
record set, so a bug that drops or mangles a record does not fail loudly — it
deletes DNS entries and returns success. These tests are the thing standing
between that and a live domain, so they assert on every record rather than
spot-checking a couple.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

import namecheap_hosts as nh  # noqa: E402

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")
MULTI_RECORD = os.path.join(FIXTURES, "gethosts-multi-record.xml")

SPF = "v=spf1 include:spf.efwd.registrar-servers.com ~all"


def load(path=MULTI_RECORD):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def wrap(hosts_xml, status="OK", email_type='EmailType="FWD"'):
    """Build a minimal getHosts response around some host elements."""
    return (
        f'<?xml version="1.0" encoding="utf-8"?>'
        f'<ApiResponse Status="{status}" xmlns="http://api.namecheap.com/xml.response">'
        f"<Errors /><CommandResponse>"
        f'<DomainDNSGetHostsResult Domain="example.org" {email_type}>'
        f"{hosts_xml}"
        f"</DomainDNSGetHostsResult></CommandResponse></ApiResponse>"
    )


HOST = (
    '<host HostId="1" Name="{name}" Type="{type}" Address="{address}" '
    'MXPref="10" TTL="1799" AssociatedAppTitle="" FriendlyName="" '
    'IsActive="{active}" IsDDNSEnabled="false" />'
)


class TestParse(unittest.TestCase):
    def test_parses_every_record(self):
        parsed = nh.parse_get_hosts(load())
        self.assertEqual(len(parsed["records"]), 10)
        self.assertEqual(parsed["email_type"], "FWD")
        self.assertEqual(parsed["domain"], "example.org")

    def test_preserves_spf_string_exactly(self):
        """Spaces, '=', ':' and '~' must survive parsing untouched."""
        parsed = nh.parse_get_hosts(load())
        txt = [r for r in parsed["records"] if r["RecordType"] == "TXT"]
        self.assertIn(SPF, [r["Address"] for r in txt])

    def test_rejects_empty_host_list(self):
        """An empty parse is how a domain gets wiped — it must never proceed."""
        with self.assertRaises(nh.NamecheapError) as ctx:
            nh.parse_get_hosts(wrap(""))
        self.assertIn("zero host records", str(ctx.exception))

    def test_rejects_non_ok_status(self):
        with self.assertRaises(nh.NamecheapError) as ctx:
            nh.parse_get_hosts(wrap(HOST.format(name="@", type="A", address="1.2.3.4", active="true"), status="ERROR"))
        self.assertIn("Status", str(ctx.exception))

    def test_rejects_missing_email_type(self):
        """Guessing EmailType would silently change the domain's mail routing."""
        with self.assertRaises(nh.NamecheapError) as ctx:
            nh.parse_get_hosts(
                wrap(HOST.format(name="@", type="A", address="1.2.3.4", active="true"), email_type="")
            )
        self.assertIn("EmailType", str(ctx.exception))

    def test_rejects_malformed_xml(self):
        with self.assertRaises(nh.NamecheapError):
            nh.parse_get_hosts("<ApiResponse><unclosed>")


class TestRoundTrip(unittest.TestCase):
    def test_every_untouched_record_survives(self):
        """The core property: rebuild changes exactly one address, nothing else."""
        parsed = nh.parse_get_hosts(load())
        before = [
            (r["HostName"], r["RecordType"], r["Address"], r["MXPref"], r["TTL"])
            for r in parsed["records"]
        ]

        nh.replace_address(parsed, "play", "A", "192.0.2.99")
        params = nh.to_set_hosts_params(parsed)

        # Reassemble the parameter stream back into records so we compare
        # what would actually go over the wire, not our in-memory objects.
        emitted = {}
        for line in params:
            key, _, value = line.partition("=")
            emitted[key] = value

        self.assertEqual(emitted["EmailType"], "FWD")

        rebuilt = []
        index = 1
        while f"HostName{index}" in emitted:
            rebuilt.append(
                (
                    emitted[f"HostName{index}"],
                    emitted[f"RecordType{index}"],
                    emitted[f"Address{index}"],
                    emitted[f"MXPref{index}"],
                    emitted[f"TTL{index}"],
                )
            )
            index += 1

        self.assertEqual(len(rebuilt), len(before), "record count must not change")

        expected = [
            r if r[0] != "play" else (r[0], r[1], "192.0.2.99", r[3], r[4])
            for r in before
        ]
        self.assertEqual(rebuilt, expected)

    def test_spf_survives_the_full_rebuild(self):
        parsed = nh.parse_get_hosts(load())
        nh.replace_address(parsed, "play", "A", "192.0.2.99")
        params = nh.to_set_hosts_params(parsed)
        self.assertTrue(
            any(line.endswith("=" + SPF) for line in params),
            "SPF record did not survive the rebuild intact",
        )

    def test_ttl_and_mxpref_variation_preserved(self):
        """The SPF record has MXPref=0 / TTL=1800 while others are 10 / 1799."""
        parsed = nh.parse_get_hosts(load())
        params = nh.to_set_hosts_params(parsed)
        self.assertIn("MXPref9=0", params)
        self.assertIn("TTL9=1800", params)


class TestReplace(unittest.TestCase):
    def test_replaces_and_returns_old_address(self):
        parsed = nh.parse_get_hosts(load())
        old = nh.replace_address(parsed, "play", "A", "192.0.2.99")
        self.assertEqual(old, "192.0.2.41")

    def test_refuses_when_record_absent(self):
        """Never create. A missing record means the caller's model is wrong."""
        parsed = nh.parse_get_hosts(load())
        with self.assertRaises(nh.NamecheapError) as ctx:
            nh.replace_address(parsed, "nosuchname", "A", "192.0.2.99")
        self.assertIn("never creates", str(ctx.exception))

    def test_refuses_ambiguous_match(self):
        """Two 'www' A records: updating one would split the name's answers."""
        parsed = nh.parse_get_hosts(load())
        with self.assertRaises(nh.NamecheapError) as ctx:
            nh.replace_address(parsed, "www", "A", "192.0.2.99")
        self.assertIn("ambiguous", str(ctx.exception))

    def test_type_match_is_case_insensitive(self):
        parsed = nh.parse_get_hosts(load())
        nh.replace_address(parsed, "play", "a", "192.0.2.99")


class TestRoundTrippability(unittest.TestCase):
    def test_refuses_inactive_records(self):
        """setHosts has no IsActive parameter, so a disabled record would
        come back enabled — an invisible change to live DNS."""
        xml = wrap(
            HOST.format(name="@", type="A", address="1.2.3.4", active="true")
            + HOST.format(name="off", type="A", address="5.6.7.8", active="false")
        )
        parsed = nh.parse_get_hosts(xml)
        with self.assertRaises(nh.NamecheapError) as ctx:
            nh.assert_round_trippable(parsed)
        self.assertIn("off A", str(ctx.exception))

    def test_accepts_all_active(self):
        nh.assert_round_trippable(nh.parse_get_hosts(load()))


if __name__ == "__main__":
    unittest.main(verbosity=2)

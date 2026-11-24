"""Tests for scripts/lib/mask-ip.pl (Saturday 2026-11-14 item 4). Public cases use the RFC 5737 documentation ranges
(192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24); private cases use RFC 1918. The one exception is 172.32.0.1, the first
address past 172.16.0.0/12, used only to test that boundary.

    python3 -I -m unittest discover -s agent/tests -p 'test_mask_ip.py' -v
"""
from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tooling import have_perl  # noqa: E402

HELPER = Path(__file__).resolve().parents[2] / "scripts" / "lib" / "mask-ip.pl"


def mask(text: str) -> str:
    proc = subprocess.run(["perl", str(HELPER)], input=text, capture_output=True, text=True, timeout=20)
    if proc.returncode:
        raise AssertionError(proc.stderr)
    return proc.stdout


@unittest.skipUnless(have_perl(), "perl not available")
class MaskIp(unittest.TestCase):
    def test_public_addresses_are_masked(self):
        for ip in ("203.0.113.7", "198.51.100.200", "192.0.2.1", "255.255.255.255", "172.32.0.1"):
            with self.subTest(ip=ip):
                self.assertEqual(mask(f"addr {ip} end\n"), "addr <ip> end\n")

    def test_private_addresses_keep_three_octets(self):
        self.assertEqual(mask("192.168.1.4\n"), "192.168.1.x\n")
        self.assertEqual(mask("10.20.30.40\n"), "10.20.30.x\n")
        self.assertEqual(mask("172.16.5.9 172.31.0.1\n"), "172.16.5.x 172.31.0.x\n")

    def test_the_11_13_refusal_shape_and_punctuation(self):
        text = ('{"statusCode": 403, "message": "Request originated from client public IP address 203.0.113.7, '
                'public network access is disabled."}\n')
        out = mask(text)
        self.assertIn("IP address <ip>, public", out)
        self.assertNotIn("203.0.113.7", out)
        self.assertEqual(mask("ip=198.51.100.9;next=(203.0.113.10)\n"), "ip=<ip>;next=(<ip>)\n")

    def test_several_on_one_line_and_across_lines(self):
        self.assertEqual(mask("a 203.0.113.1 b 192.168.3.4\nc 198.51.100.2\n"), "a <ip> b 192.168.3.x\nc <ip>\n")

    def test_things_that_are_not_one_address_are_left_alone(self):
        for text in ("version 1.2.3.4.5", "256.1.1.1", "1.2.3.4567", "api-version=2024-05-01", "v12.0.1",
                     "001.002.003.004"):
            with self.subTest(text=text):
                self.assertEqual(mask(text + "\n"), text + "\n")

    def test_no_bsd_sed_word_boundary(self):
        self.assertNotIn("\\b", HELPER.read_text(encoding="utf-8").split("use warnings;", 1)[1])


if __name__ == "__main__":
    unittest.main()

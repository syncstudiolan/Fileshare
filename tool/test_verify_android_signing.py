import unittest

from verify_android_signing import compare_outputs, fingerprints


class AndroidSigningTest(unittest.TestCase):
    # Public certificate digest from production build 596 and build 623 logs.
    production = "d4dfbbd696ae47ea2473a1a588dea280fd70f354fd84f3eda20f788f4e70ab52"

    def test_actual_new_sdk_log_format(self):
        line = f"V2 Signer: certificate SHA-256 digest: {self.production}"
        self.assertEqual(compare_outputs(line, line), {self.production})

    def test_legacy_and_current_sdk_formats_match(self):
        old = f"Signer #1 certificate SHA-256 digest: {self.production}"
        new = f"V2 Signer: certificate SHA-256 digest: {self.production.upper()}"
        self.assertEqual(compare_outputs(old, new), {self.production})

    def test_numbered_new_format_and_duplicate_schemes(self):
        line = f"V3.1 Signer #1: certificate SHA-256 digest: {self.production}"
        other = f"V2 Signer: certificate SHA-256 digest: {self.production}"
        self.assertEqual(compare_outputs(other, line + "\n" + other), {self.production})

    def test_real_signing_mismatch_is_rejected(self):
        old = f"V2 Signer: certificate SHA-256 digest: {self.production}"
        new = f"V2 Signer: certificate SHA-256 digest: {'a' * 64}"
        with self.assertRaisesRegex(ValueError, "signing identity differs"):
            compare_outputs(old, new)

    def test_unrecognized_output_and_public_key_are_not_certificates(self):
        for output in ("", f"V2 Signer: public key SHA-256 digest: {self.production}",
                       "Signer #1 certificate SHA-256 digest: invalid"):
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "no recognized"):
                fingerprints(output)

    def test_multiple_distinct_signers_rejected(self):
        output = (f"Signer #1 certificate SHA-256 digest: {self.production}\n"
                  f"Signer #2 certificate SHA-256 digest: {'b' * 64}")
        with self.assertRaisesRegex(ValueError, "signing identity differs"):
            compare_outputs(output, output)


if __name__ == "__main__":
    unittest.main()

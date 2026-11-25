#!/usr/bin/env python3
"""Prepare public India PKI issuer assets; never add downloaded trust roots."""
import concurrent.futures
import hashlib
import json
import pathlib
import ssl
import subprocess
import tempfile
import urllib.parse
import urllib.request

ASSETS = pathlib.Path(__file__).resolve().parents[1] / "android/app/src/main/assets/dsc"
PIN = "9a3fd3176798e842ddcb12c262f11cfacca70a8b84c6ea6fda30842a95a94cd8"
MAX = 128 * 1024
PREFIX = "/cca/sites/default/files/files/"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def check_url(url):
    u = urllib.parse.urlsplit(url)
    if (u.scheme != "https" or u.netloc != "cca.gov.in" or
            not u.path.startswith(PREFIX) or u.query or u.fragment or
            "/" in urllib.parse.unquote(u.path[len(PREFIX):]) or
            not u.path.lower().endswith(".cer")):
        raise ValueError("Not an official certificate URL")


def openssl(*args, input=None):
    return subprocess.check_output(["openssl", *map(str, args)], input=input,
                                   stderr=subprocess.PIPE, timeout=10)


def validated_pem(raw, root):
    if not 0 < len(raw) <= MAX:
        raise ValueError("Invalid certificate length")
    try:
        pem = openssl("x509", "-inform", "DER", "-outform", "PEM", input=raw)
    except subprocess.CalledProcessError:
        pem = openssl("x509", "-inform", "PEM", "-outform", "PEM", input=raw)
    der = openssl("x509", "-outform", "DER", input=pem)
    extensions = openssl("x509", "-noout", "-ext", "basicConstraints,keyUsage", input=pem)
    if b"CA:TRUE" not in extensions or b"Certificate Sign" not in extensions:
        raise ValueError("Not an issuing CA")
    subject = openssl("x509", "-noout", "-subject", "-nameopt", "RFC2253", input=pem).split(b"=",1)[1].strip()
    issuer = openssl("x509", "-noout", "-issuer", "-nameopt", "RFC2253", input=pem).split(b"=",1)[1].strip()
    root_subject = openssl("x509", "-in", root, "-noout", "-subject", "-nameopt", "RFC2253").split(b"=",1)[1].strip()
    if subject == issuer or issuer != root_subject:
        raise ValueError("Not an issuer directly under the pinned root")
    with tempfile.TemporaryDirectory() as d:
        cert = pathlib.Path(d) / "issuer.pem"
        cert.write_bytes(pem)
        openssl("verify", "-no-CApath", "-no-CAstore", "-CAfile", root,
                "-no_check_time", "-purpose", "any", cert)
    return hashlib.sha256(der).hexdigest(), pem


def main():
    root = ASSETS / "CCAIndia2022.pem"
    catalog = json.loads((ASSETS / "india-ca-catalog.json").read_text())
    if catalog["root_sha256"] != PIN or hashlib.sha256(
            openssl("x509", "-in", root, "-outform", "DER")).hexdigest() != PIN:
        raise SystemExit("Pinned CCA root mismatch; refusing issuer provisioning")
    output = ASSETS / "issuers"
    output.mkdir(exist_ok=True)
    def fetch(entry):
        try:
            check_url(entry["url"])
            opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=ssl.create_default_context()))
            req = urllib.request.Request(entry["url"], headers={"User-Agent": "FileShare-CA-Catalog/1.0"})
            with opener.open(req, timeout=8) as response:
                data = response.read(MAX + 1)
            fingerprint, pem = validated_pem(data, root)
            (output / (fingerprint + ".pem")).write_bytes(pem)
            return entry["name"], fingerprint
        except Exception as exc:
            return entry["name"], None
    entries = catalog["entries"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(fetch, entries))
    for name, fingerprint in results:
        print(name + ": " + (fingerprint or "unavailable or failed validation"))
    print(f"Official issuer certificates prepared: {sum(bool(f) for _, f in results)}/{len(entries)}")
    print("Unavailable issuers can be retrieved automatically on-device; no trust checks are bypassed.")

if __name__ == "__main__":
    main()

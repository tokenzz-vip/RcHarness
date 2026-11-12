"""Validate generated metadata against the sealed application in its ZIP."""
import base64
import plistlib
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


def validate(feed, archive, tag, repository):
    ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read("RcHarness.app/Contents/Info.plist"))
    items = ET.parse(feed).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("The release feed must contain exactly one update")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("Missing update enclosure")
    signature = enclosure.get("{" + ns["s"] + "}edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Missing or invalid EdDSA signature")
    expected = {
        "s:version": info["CFBundleVersion"],
        "s:shortVersionString": tag.removeprefix("v"),
        "s:minimumSystemVersion": info["LSMinimumSystemVersion"],
    }
    for key, value in expected.items():
        if item.findtext(key, namespaces=ns) != value:
            raise ValueError(f"Appcast {key} differs from the shipped application")
    if info["CFBundleShortVersionString"] != tag.removeprefix("v"):
        raise ValueError("App version differs from release tag")
    if enclosure.get("length") != str(Path(archive).stat().st_size):
        raise ValueError("Update archive size mismatch")
    url = f"https://github.com/{repository}/releases/download/{tag}/{Path(archive).name}"
    if enclosure.get("url") != url:
        raise ValueError("Unexpected download URL")


if __name__ == "__main__":
    validate(*sys.argv[1:])

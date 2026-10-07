#!/usr/bin/env python3
"""appcast.py <appcast.xml> <version> <build> <url> <sign_update output> [channel]

Adds a release to the Sparkle appcast, newest first, creating the file if it
doesn't exist. Run by scripts/release.sh."""
import os, re, sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
RELEASES = "https://github.com/sorrycc/Deckle/releases"
MINIMUM_SYSTEM = "26.0"   # LSMinimumSystemVersion in scripts/bundle.sh

def sp(name): return f"{{{SPARKLE}}}{name}"

def main(path, version, build, url, signature, channel=""):
    fields = dict(re.findall(r'(sparkle:edSignature|length)="([^"]+)"', signature))
    if len(fields) != 2: sys.exit(f"can't read sign_update output: {signature}")
    if os.path.exists(path):
        tree = ET.parse(path)
    else:
        rss = ET.Element("rss", {"version": "2.0"}); ch = ET.SubElement(rss, "channel")
        ET.SubElement(ch, "title").text = "Deckle"; ET.SubElement(ch, "link").text = RELEASES
        tree = ET.ElementTree(rss)
    feed = tree.getroot().find("channel")
    # Releasing the same build again replaces its item.
    for item in feed.findall("item"):
        if item.findtext(sp("version")) == build: feed.remove(item)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = version
    ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
    ET.SubElement(item, sp("version")).text = build
    ET.SubElement(item, sp("shortVersionString")).text = version
    ET.SubElement(item, sp("minimumSystemVersion")).text = MINIMUM_SYSTEM
    ET.SubElement(item, sp("fullReleaseNotesLink")).text = f"{RELEASES}/tag/v{version}"
    if channel: ET.SubElement(item, sp("channel")).text = channel
    ET.SubElement(item, "enclosure", {"url": url, "type": "application/octet-stream",
        sp("edSignature"): fields["sparkle:edSignature"], "length": fields["length"]})
    first = next((i for i, c in enumerate(feed) if c.tag == "item"), len(feed))
    feed.insert(first, item)
    ET.indent(tree); tree.write(path, encoding="utf-8", xml_declaration=True)

if __name__ == "__main__":
    if len(sys.argv) not in (6, 7): sys.exit(__doc__)
    main(*sys.argv[1:])

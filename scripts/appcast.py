#!/usr/bin/env python3
"""appcast.py <appcast.xml> <version> <build> <url> <sign_update output> <notes.md> [channel]

Adds a release to the Sparkle appcast, newest first, creating the file if it
doesn't exist. <notes.md> holds the release's notes from CHANGELOG.md, which
the update window shows; an empty file leaves them out. Run by
scripts/release.sh."""
import html, os, re, sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
RELEASES = "https://github.com/sorrycc/Deckle/releases"
MINIMUM_SYSTEM = "15.0"   # LSMinimumSystemVersion in scripts/bundle.sh

def sp(name): return f"{{{SPARKLE}}}{name}"

def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    return re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", lambda m: f'<a href="{html.escape(m[2])}">{m[1]}</a>', text)

def notes_html(markdown):
    """The little Markdown CHANGELOG.md uses, paragraphs and "- " lists with
    wrapped lines, as the HTML Sparkle's update window shows."""
    blocks = []
    for block in re.split(r"\n\s*\n", markdown.strip()):
        items = re.split(r"^- ", block, flags=re.M)
        if items[0].strip():
            blocks.append(f"<p>{inline(' '.join(items[0].split()))}</p>")
        if len(items) > 1:
            blocks.append("<ul>" + "".join(f"<li>{inline(' '.join(i.split()))}</li>" for i in items[1:]) + "</ul>")
    return "\n".join(blocks)

def main(path, version, build, url, signature, notes, channel=""):
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
    with open(notes) as f: description = notes_html(f.read())
    if description: ET.SubElement(item, "description").text = description
    if channel: ET.SubElement(item, sp("channel")).text = channel
    ET.SubElement(item, "enclosure", {"url": url, "type": "application/octet-stream",
        sp("edSignature"): fields["sparkle:edSignature"], "length": fields["length"]})
    first = next((i for i, c in enumerate(feed) if c.tag == "item"), len(feed))
    feed.insert(first, item)
    ET.indent(tree); tree.write(path, encoding="utf-8", xml_declaration=True)

if __name__ == "__main__":
    if len(sys.argv) not in (7, 8): sys.exit(__doc__)
    main(*sys.argv[1:])

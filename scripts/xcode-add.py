#!/usr/bin/env python3
"""Adds files and package products to NTFSForMac.xcodeproj, standing in for xcodegen.

  scripts/xcode-add.py file App/Transfer/TransferSession.swift [more files...]
  scripts/xcode-add.py file AppTests/TransferTextTests.swift
  scripts/xcode-add.py product NTFSTransfer

Files under App/ go to the NTFSForMac target, files under AppTests/ to NTFSForMacTests.
`product` links a product of the local Core package into the NTFSForMac target.
Running a command twice changes nothing.
"""
import hashlib
import pathlib
import re
import sys

PROJECT = pathlib.Path(__file__).resolve().parent.parent / "NTFSForMac.xcodeproj" / "project.pbxproj"
TARGETS = {"App": "NTFSForMac", "AppTests": "NTFSForMacTests"}
GROUP = re.compile(
    r"\t\t(?P<id>[0-9A-F]{24}) /\* (?P<name>[^\n]*?) \*/ = \{\n\t\t\tisa = PBXGroup;\n"
    r"\t\t\tchildren = \(\n(?P<children>.*?)\t\t\t\);\n(?P<rest>.*?)\t\t\};\n",
    re.S,
)


def ident(seed):
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


def append_to_section(text, section, block):
    marker = f"/* End {section} section */"
    at = text.index(marker)
    return text[:at] + block + text[at:]


def groups(text):
    return list(GROUP.finditer(text))


def append_to_list(text, start_pattern, line):
    """Adds `line` as the last entry of the parenthesised list that follows `start_pattern`."""
    match = re.search(start_pattern + r"(?P<items>.*?)\t\t\t\);\n", text, re.S)
    if not match:
        raise SystemExit(f"list not found: {start_pattern}")
    at = match.end("items")
    return text[:at] + line + text[at:]


def find_group(text, parent_id, path):
    for match in groups(text):
        if f"path = {path};" not in match["rest"]:
            continue
        if parent_id is None or match["id"] in parent_children(text, parent_id):
            return match["id"]
    return None


def parent_children(text, group_id):
    match = next(m for m in groups(text) if m["id"] == group_id)
    return match["children"]


def ensure_group(text, directory):
    """Returns the id of the group for `directory` (like App/Transfer), creating missing ones."""
    parent = None
    walked = []
    for part in directory.split("/"):
        walked.append(part)
        found = find_group(text, parent, part)
        if found is None:
            if parent is None:
                raise SystemExit(f"no top-level group for {part}")
            found = ident("group:" + "/".join(walked))
            block = (
                f"\t\t{found} /* {part} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t);\n"
                f'\t\t\tpath = {part};\n\t\t\tsourceTree = "<group>";\n\t\t}};\n'
            )
            text = append_to_section(text, "PBXGroup", block)
            text = add_group_child(text, parent, f"\t\t\t\t{found} /* {part} */,\n")
        parent = found
    return text, parent


def add_group_child(text, group_id, line):
    match = next(m for m in groups(text) if m["id"] == group_id)
    at = match.start("children") + len(match["children"])
    return text[:at] + line + text[at:]


def target_body(text, target):
    pattern = re.compile(r"\t\t[0-9A-F]{24} /\* [^\n]*? \*/ = \{\n\t\t\tisa = PBXNativeTarget;\n(?P<body>.*?)\n\t\t\};\n", re.S)
    for match in pattern.finditer(text):
        if f"name = {target};" in match["body"]:
            return match
    raise SystemExit(f"target not found: {target}")


def phase_id(text, target, phase):
    body = target_body(text, target)["body"]
    found = re.search(rf"([0-9A-F]{{24}}) /\* {phase} \*/", body)
    if not found:
        raise SystemExit(f"{phase} phase not found in {target}")
    return found.group(1)


def add_file(text, relative):
    path = pathlib.PurePosixPath(relative)
    name = path.name
    if re.search(rf"/\* {re.escape(name)} \*/ = \{{isa = PBXFileReference", text):
        return text
    target = TARGETS[path.parts[0]]
    ref, build = ident("ref:" + relative), ident("build:" + relative)
    text = append_to_section(
        text, "PBXBuildFile",
        f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n")
    text = append_to_section(
        text, "PBXFileReference",
        f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
        f'path = {name}; sourceTree = "<group>"; }};\n')
    text, group = ensure_group(text, str(path.parent))
    text = add_group_child(text, group, f"\t\t\t\t{ref} /* {name} */,\n")
    sources = phase_id(text, target, "Sources")
    return append_to_list(
        text, rf"{sources} /\* Sources \*/ = \{{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n",
        f"\t\t\t\t{build} /* {name} in Sources */,\n")


def add_product(text, product):
    if f"productName = {product};" in text:
        return text
    target = "NTFSForMac"
    ref, build = ident("product:" + product), ident("productbuild:" + product)
    text = append_to_section(
        text, "PBXBuildFile",
        f"\t\t{build} /* {product} in Frameworks */ = {{isa = PBXBuildFile; productRef = {ref} /* {product} */; }};\n")
    text = append_to_section(
        text, "XCSwiftPackageProductDependency",
        f"\t\t{ref} /* {product} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = {product};\n\t\t}};\n")
    frameworks = phase_id(text, target, "Frameworks")
    text = append_to_list(
        text, rf"{frameworks} /\* Frameworks \*/ = \{{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n",
        f"\t\t\t\t{build} /* {product} in Frameworks */,\n")
    body = target_body(text, target)
    start = body.start("body")
    inner = text[start:body.end("body")]
    marker = "packageProductDependencies = (\n"
    at = start + inner.index(marker) + len(marker)
    end = text.index("\t\t\t);", at)
    return text[:end] + f"\t\t\t\t{ref} /* {product} */,\n" + text[end:]


def main(arguments):
    if len(arguments) < 2 or arguments[0] not in ("file", "product"):
        raise SystemExit(__doc__)
    text = PROJECT.read_text()
    for item in arguments[1:]:
        text = add_file(text, item) if arguments[0] == "file" else add_product(text, item)
    PROJECT.write_text(text)


main(sys.argv[1:])

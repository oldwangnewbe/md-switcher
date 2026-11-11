"""Read the two local card databases and build a patch for one illustration."""

import argparse
from collections import defaultdict
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import struct
import sys
import zipfile
import zlib

archive = Path(__file__).with_name("site.zip")
if archive.is_file():
    directory = Path(os.environ["MD_SWITCHER_WORK"]) / "site"
    with zipfile.ZipFile(archive) as packaged:
        packaged.extractall(directory)
    sys.path.insert(0, str(directory / "card-search-site"))

from PIL import Image, ImageOps
import UnityPy

from generate_sky_striker import find_texture, mdpro3_artwork_ids, replacement, sha


def bundle_path(logical_path):
    key = f"{zlib.crc32(logical_path.encode()):08x}"
    return f"{key[:2]}/{key}"


def text_asset(path, name):
    matches = [obj.read() for obj in UnityPy.load(str(path)).objects if obj.type.name == "TextAsset"]
    matches = [obj for obj in matches if obj.m_Name == name]
    if len(matches) != 1:
        raise ValueError(f"Missing {name} text asset")
    return matches[0].m_Script.encode("utf-8", "surrogateescape")


def unmask(data, key):
    return bytes(value ^ ((((index + key + 0x23d) * key) ^ (index % 7)) & 255)
                 for index, value in enumerate(data))


def decrypt_table(data):
    # The local CARD_* assets use a byte mask around a zlib stream.
    # Format reference: https://gist.github.com/akintos/04e2494c62184d2d4384078b0511673b
    for key in range(256):
        first, second = unmask(data[:2], key)
        if first != 0x78 or (first * 256 + second) % 31:
            continue
        try:
            return zlib.decompress(unmask(data, key))
        except zlib.error:
            continue
    raise ValueError("Unsupported Master Duel card data encoding")


def card_tables(cache, index):
    salt = "52e6df8c24142856"
    locales = ("zh-CN", "en-US", "ja-JP")
    for locale in locales:
        prop = bundle_path(f"Card/Data/{salt}/{locale}/CARD_Prop")
        if prop in index and (cache / prop).is_file():
            return salt, locale

    # The content version changes the logical path after a game update.
    pattern = re.compile(r"/card/data/([0-9a-f]+)/([^/]+)/card_prop\.bytes$", re.I)
    found = {}
    for relative, entry in index.items():
        if not 8_192 <= entry["bytes"] <= 2_500_000:
            continue
        path = cache / relative
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            header = stream.read(12_000)
        if b"card_prop" not in header.lower():
            continue
        try:
            for name in UnityPy.load(str(path)).container:
                match = pattern.search(name)
                if match:
                    found[match[2].lower()] = match[1]
        except (ValueError, OSError, KeyError, EOFError):
            continue
        if "zh-cn" in found:
            break
    for locale in locales:
        if locale.lower() in found:
            return found[locale.lower()], locale
    raise ValueError("Master Duel card tables not found; finish downloading the main account resources")


def master_duel_names(cache, tables):
    salt, locale = tables

    def table(name):
        path = cache / bundle_path(f"Card/Data/{salt}/{locale}/{name}")
        return decrypt_table(text_asset(path, name))

    properties, offsets, names = (table(name) for name in ("CARD_Prop", "CARD_Indx", "CARD_Name"))
    if len(properties) % 8 or len(offsets) < len(properties) + 8:
        raise ValueError("Invalid Master Duel card table lengths")
    result = {}
    for offset in range(8, len(properties), 8):
        cid = struct.unpack_from("<H", properties, offset)[0]
        start = struct.unpack_from("<I", offsets, offset)[0]
        end = struct.unpack_from("<I", offsets, offset + 8)[0]
        if not 0 <= start <= end <= len(names):
            raise ValueError("Invalid Master Duel card name offset")
        name = names[start:end].rstrip(b"\0").decode()
        if cid and name:
            result[cid] = name

    same = {variant: base for variant, base, _ in struct.iter_unpack("<HHH", table("CARD_Same"))
            if variant in result and base in result and variant != base}
    return result, same


def local_art(directory):
    if not directory.is_dir():
        return {}
    return {int(path.stem): path for path in sorted(directory.iterdir())
            if path.is_file() and path.stem.isascii() and path.stem.isdigit()
            and path.suffix.lower() in (".jpg", ".jpeg", ".png")}


def pro_catalog(mdpro3):
    database = mdpro3 / "Data/locales/zh-CN/cards.cdb"
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as db:
        rows = {code: (alias, name, setcode, description) for code, alias, name, setcode, description in db.execute(
            "SELECT d.id, d.alias, t.name, d.setcode, t.desc FROM datas d JOIN texts t ON t.id = d.id"
        )}
    groups = defaultdict(list)
    root_for = {}
    for code, (alias, name, _, _) in rows.items():
        root = alias if alias in rows and rows[alias][1] == name else code
        groups[root].append(code)
        root_for[code] = root
    return rows, groups, root_for


def set_names(mdpro3):
    path = mdpro3 / "Data/locales/zh-CN/strings.conf"
    if not path.is_file():
        return {}
    names = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        match = re.match(r"^!setname\s+0x([0-9a-f]+)\s+([^\t]+)", line, re.I)
        if match:
            names[int(match[1], 16)] = match[2].split("#", 1)[0].strip()
    return names


def card_series(row, set_labels):
    _, name, setcode, description = row
    description = description or ""
    codes = {(setcode >> shift) & 0xffff for shift in range(0, 64, 16)}
    bases = {code & 0xfff for code in codes}
    result = {set_labels[code] for code in codes | bases if code in set_labels}
    if bases.intersection((0x15d, 0x164, 0x188)) or name == "阿不思的落胤" or any(
        reference in description for reference in ("「阿不思的落胤」", "「烙印」")
    ):
        result.add("烙印")
    if any((code & 0x1fff) == 0x10a2 for code in codes) or any(
        reference in description for reference in ("「黑魔术师」", "「黑魔术少女」")
    ):
        result.update(("黑魔导", "黑魔术"))
    return sorted(result)


def search_index(cache, mdpro3, output, include_over_frame=False):
    manifest = json.loads((cache / "86/868ffd0e").read_bytes())
    index = {item["assetName"]: item for item in manifest["informations"]
             if re.fullmatch(r"[0-9a-f]{2}/[0-9a-f]{8}", item["assetName"])}
    tables = card_tables(cache, index)
    names, same = master_duel_names(cache, tables)
    rows, groups, root_for = pro_catalog(mdpro3)
    set_labels = set_names(mdpro3)
    images = local_art(mdpro3 / "Picture/Art")
    over_frames = local_art(mdpro3 / "Picture/OverFrame") if include_over_frame else {}
    gate = bundle_path(f"Card/Data/{tables[0]}/MD/of_card_asset")
    if gate not in index or not (cache / gate).is_file():
        gate = "22/22817d01" if "22/22817d01" in index and (cache / "22/22817d01").is_file() else None
    mappings = mdpro3_artwork_ids(mdpro3)
    by_root = defaultdict(set)
    for cid, code in mappings.items():
        if cid in names and code in root_for:
            by_root[root_for[code]].add(same.get(cid, cid))
    roots_by_cid = defaultdict(set)
    for root, candidates in by_root.items():
        if len(candidates) == 1:
            roots_by_cid[next(iter(candidates))].add(root)
    master_ids = defaultdict(list)
    for variant, base in same.items():
        master_ids[base].append(variant)

    records = []
    used = set()
    for cid, name in names.items():
        if cid in same:
            continue
        roots = roots_by_cid[cid]
        direct = root_for.get(mappings.get(cid))
        root = direct if direct in roots else next(iter(roots)) if len(roots) == 1 else None
        if root is not None:
            used.add(root)
        codes = groups[root] if root is not None else []
        original = mappings.get(cid)
        if original not in codes:
            original = root
        variants = artwork_variants(codes, original, images, over_frames, gate)
        path = next((relative for region in ("tcg", "common", "ocg")
                     if (relative := bundle_path(f"Card/Images/Illust/{region}/{cid}")) in index
                     and (cache / relative).is_file()), None)
        records.append({"id": f"md-{cid}", "cid": cid, "masterName": name, "proName": rows[root][1] if root else None,
                        "codes": sorted(codes), "masterIDs": sorted(master_ids[cid]), "variants": variants, "path": path,
                        "series": card_series(rows[root], set_labels) if root else [],
                        "previewFile": artwork_preview(codes, original, root, images),
                        "originalPreviewPath": original_preview_path(original, images, over_frames)})
    for root, codes in groups.items():
        if root not in used:
            records.append({"id": f"pro-{root}", "proName": rows[root][1], "codes": sorted(codes), "masterIDs": [],
                            "variants": artwork_variants(codes, root, images, over_frames, gate),
                            "series": card_series(rows[root], set_labels),
                            "previewFile": artwork_preview(codes, root, root, images),
                            "originalPreviewPath": original_preview_path(root, images, over_frames)})
    output.write_text(json.dumps(records, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


def artwork_preview(codes, original, root, images):
    path = images.get(original) or images.get(root)
    if path is None:
        path = next((images[code] for code in sorted(codes) if code in images), None)
    return path.name if path else None


def original_preview_path(code, images, over_frames):
    path = images.get(code) or over_frames.get(code)
    return f"{path.parent.name}/{path.name}" if path else None


def artwork_variants(codes, original, images, over_frames, gate):
    if len(codes) < 2:
        return []
    sources = images | over_frames
    seen = {hashlib.sha256(sources[original].read_bytes()).digest()} if original in sources else set()
    variants = []
    for code in sorted(codes):
        if code == original or code not in sources:
            continue
        path = sources[code]
        digest = hashlib.sha256(path.read_bytes()).digest()
        if digest not in seen:
            seen.add(digest)
            variant = {"id": code, "file": images.get(code, path).name}
            if code in over_frames:
                variant["overFrame"] = {"file": path.name, "gate": gate}
            variants.append(variant)
    return variants


def make_patch(original_file, artwork_file, cid, relative, artwork_id, label, output, over_frame_gate=None):
    original = original_file.read_bytes()
    artwork = artwork_file.read_bytes()
    with Image.open(io.BytesIO(artwork)) as source:
        if over_frame_gate:
            from over_frame import canvas, replace_texture
            patched = replace_texture(original, cid, canvas(source))
        else:
            texture = find_texture(UnityPy.load(original), cid)
            if texture.m_Width != texture.m_Height:
                raise ValueError("This Master Duel card has a non-square texture")
            image = ImageOps.fit(source.convert("RGB"), (texture.m_Width, texture.m_Height),
                                 Image.Resampling.LANCZOS, centering=(0.5, 0.24))
            patched = replacement(original, cid, image)
    (output / f"{artwork_id}.bundle").write_bytes(patched)
    card = {"name": label, "path": relative, "originalSHA256": sha(original),
            "sourceArtwork": {"format": 2 if over_frame_gate else 1, "cid": cid, "sha256": sha(artwork)},
            "variants": [{"id": artwork_id, "sha256": sha(patched)}]}
    if over_frame_gate:
        card["overFrame"] = {"cardID": cid, "gate": over_frame_gate}
    (output / "manifest.json").write_text(json.dumps([card], ensure_ascii=False), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    index = commands.add_parser("index")
    for name in ("cache", "mdpro3", "output"):
        index.add_argument(name, type=Path)
    index.add_argument("--over-frame", action="store_true")
    patch = commands.add_parser("patch")
    patch.add_argument("original", type=Path)
    patch.add_argument("artwork", type=Path)
    patch.add_argument("cid", type=int)
    patch.add_argument("relative")
    patch.add_argument("artwork_id", type=int)
    patch.add_argument("label")
    patch.add_argument("output", type=Path)
    patch.add_argument("--over-frame-gate")
    gate = commands.add_parser("over-frame-gate")
    gate.add_argument("original", type=Path)
    gate.add_argument("output", type=Path)
    gate.add_argument("cards", type=int, nargs="+")
    summon = commands.add_parser("summon")
    for name in ("cache", "originals", "output", "pro_directory"):
        summon.add_argument(name, type=Path)
    summon.add_argument("cards", nargs="+")
    args = parser.parse_args()
    if args.command == "index":
        search_index(args.cache, args.mdpro3, args.output, args.over_frame)
    elif args.command == "patch":
        make_patch(args.original, args.artwork, args.cid, args.relative, args.artwork_id, args.label, args.output,
                   args.over_frame_gate)
    elif args.command == "over-frame-gate":
        from over_frame import rewrite_gate
        args.output.write_bytes(rewrite_gate(args.original.read_bytes(), args.cards))
    else:
        from summon_animation import make_summon_pack
        cards = [tuple(map(int, spec.split(":"))) for spec in args.cards]
        make_summon_pack(args.cache, args.originals, args.output, args.pro_directory, cards)


if __name__ == "__main__":
    main()

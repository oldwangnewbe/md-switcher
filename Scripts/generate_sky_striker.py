"""Build the private test pack from installed game files (UnityPy 1.23.0)."""

import argparse
import hashlib
import json
from pathlib import Path
import zlib

from PIL import Image, ImageChops, ImageOps, ImageStat
import UnityPy
from UnityPy.export.Texture2DConverter import image_to_texture2d
from UnityPy.streams import EndianBinaryReader


# Master Duel card ID, label, MDPro3 artwork IDs (preferred option first).
CARDS = [
    (13670, "零衣", [26077389, 26077388, 26077390]),
    (14829, "露世", [37351134, 37351135]),
    (13668, "燎里（篝）", [63288574]),
    (13669, "雫空", [90673289]),
    (13763, "飒天", [8491309]),
    (13671, "交闪", [63166096, 63166097]),
    (17034, "连刀", [9726841]),
    (13675, "黑寡妇抓锚", [98338153]),
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def mdpro3_artwork_ids(mdpro3):
    cards = json.loads((mdpro3 / "Data/cards_Lite.json").read_text(encoding="utf-8"))
    return {int(row["cid"]): int(row["id"]) for row in cards.values()}


def artwork_key(card_id):
    return f"{zlib.crc32(f'Card/Images/Illust/tcg/{card_id}'.encode()):08x}"


def write_original_preview(mdpro3, artwork_id, destination):
    art = mdpro3 / "Picture/Art"
    source = next((path for ext in ("jpg", "png", "jpeg") if (path := art / f"{artwork_id}.{ext}").is_file()), None)
    if source is None:
        return
    with Image.open(source) as image:
        preview = image.convert("RGB")
        preview.thumbnail((192, 192), Image.Resampling.LANCZOS)
        preview.save(destination, quality=88)


def find_texture(bundle, card_id):
    textures = [obj.read() for obj in bundle.objects if obj.type.name == "Texture2D"]
    if len(textures) != 1 or textures[0].m_Name != str(card_id):
        raise ValueError(f"Unexpected texture in the bundle for {card_id}")
    return textures[0]


def replacement(original, card_id, image):
    bundle = UnityPy.load(original)
    texture = find_texture(bundle, card_id)
    stream = texture.m_StreamData
    name = stream.path.rsplit("/", 1)[-1]
    old_stream = bundle.file.files[name]
    encoded, fmt = image_to_texture2d(image, texture.m_TextureFormat)
    if stream.offset != 0 or len(encoded) != stream.size or stream.size != len(old_stream.bytes):
        raise ValueError(f"Unexpected resource stream for {card_id}")
    if fmt != texture.m_TextureFormat or texture.m_MipCount != 1:
        raise ValueError(f"Unexpected texture format for {card_id}")
    new_stream = EndianBinaryReader(encoded)
    new_stream.flags = old_stream.flags
    bundle.file.files[name] = new_stream
    result = bundle.file.save(packer="lz4")

    verified = UnityPy.load(result)
    final_texture = find_texture(verified, card_id)
    if list(verified.container) != list(bundle.container) or final_texture.m_StreamData != stream:
        raise ValueError(f"Bundle layout changed for {card_id}")
    diff = ImageChops.difference(image.convert("RGB"), final_texture.image.convert("RGB"))
    if max(ImageStat.Stat(diff).mean) > 12:
        raise ValueError(f"Reopened texture differs from the source artwork for {card_id}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("master_cache", type=Path, help="Clean Master Duel account's 0000 directory")
    parser.add_argument("mdpro3", type=Path, help="MDPro3 installation folder")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    index = json.loads((args.master_cache / "86/868ffd0e").read_bytes())
    hashes = {entry["assetName"]: entry["crc"] for entry in index["informations"]}
    artwork_ids = mdpro3_artwork_ids(args.mdpro3)
    args.output.mkdir(parents=True, exist_ok=True)

    cards = []
    for card_id, label, variants in CARDS:
        key = artwork_key(card_id)
        relative = f"{key[:2]}/{key}"
        original = (args.master_cache / relative).read_bytes()
        if sha(original) != hashes[relative]:
            raise ValueError(f"Original doesn't match the game index: {relative}")
        write_original_preview(args.mdpro3, artwork_ids.get(card_id), args.output / f"original-{key}.jpg")
        options = []
        for art_id in variants:
            with Image.open(args.mdpro3 / f"Picture/Art/{art_id}.jpg") as source:
                # Fit the two full-card illustrations to the normal square art window.
                image = ImageOps.fit(source.convert("RGB"), (512, 512),
                                     Image.Resampling.LANCZOS, centering=(0.5, 0.24))
            image.resize((192, 192), Image.Resampling.LANCZOS).save(
                args.output / f"{art_id}.jpg", quality=88
            )
            patched = replacement(original, card_id, image)
            (args.output / f"{art_id}.bundle").write_bytes(patched)
            options.append({"id": art_id, "sha256": sha(patched)})
        cards.append({"name": label, "path": relative, "originalSHA256": sha(original), "variants": options})

    (args.output / "manifest.json").write_text(
        json.dumps(cards, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Verified {sum(len(card['variants']) for card in cards)} replacements for {len(cards)} cards.")


if __name__ == "__main__":
    main()

"""Encode Master Duel's full-card art and edit its per-account over-frame table."""

import struct

from PIL import Image, ImageDraw, ImageFilter, ImageOps
import UnityPy
from UnityPy.enums import TextureFormat
from UnityPy.export.Texture2DConverter import image_to_texture2d
from UnityPy.streams import EndianBinaryReader

from generate_sky_striker import find_texture

SIZE = (704, 1024)
GATE_NAME = "of_card_asset"


def canvas(source):
    rgb = source.convert("RGB")
    alpha = source.getchannel("A") if "A" in source.getbands() else None

    if alpha is not None and alpha.getextrema()[0] < 255:
        # Native MD images may store the card at 512×1024. Scale their RGB
        # separately because low alpha is a foil mask, not disposable color.
        if source.size in (SIZE, (512, 1024)):
            rgb = rgb.resize(SIZE, Image.Resampling.LANCZOS)
            alpha = alpha.resize(SIZE, Image.Resampling.LANCZOS)
        else:
            background = ImageOps.fit(rgb, SIZE, Image.Resampling.LANCZOS)
            fitted = ImageOps.contain(rgb, SIZE, Image.Resampling.LANCZOS)
            mask = alpha.resize(fitted.size, Image.Resampling.LANCZOS)
            origin = ((SIZE[0] - fitted.width) // 2, (SIZE[1] - fitted.height) // 2)
            background.paste(fitted, origin, mask)
            rgb = background
            alpha = Image.new("L", SIZE, 4)
            alpha.paste(mask, origin)
        rgb.putalpha(alpha)
        return rgb

    # MDPro3's JPEGs are full illustrations without a foil mask or text box.
    # Keep their full composition and leave a translucent area for game text.
    rgb = rgb.resize(SIZE, Image.Resampling.LANCZOS)
    mask = Image.new("L", SIZE)
    ImageDraw.Draw(mask).rounded_rectangle((39, 761, 665, 965), radius=9, fill=165)
    rgb = Image.composite(Image.new("RGB", SIZE, (238, 231, 217)), rgb, mask)
    border = Image.new("L", SIZE, 255)
    ImageDraw.Draw(border).rounded_rectangle((21, 20, 682, 1003), radius=14, fill=4)
    alpha = border.filter(ImageFilter.GaussianBlur(2))
    alpha.paste(255, (0, 0), mask)
    rgb.putalpha(alpha)
    return rgb


def replace_texture(original, card_id, image):
    env = UnityPy.load(original)
    texture = find_texture(env, card_id)
    if texture.m_MipCount != 1 or texture.m_TextureFormat != TextureFormat.BC7:
        raise ValueError("Unrecognized Master Duel card texture format")
    encoded, fmt = image_to_texture2d(image, TextureFormat.BC7)
    if fmt != TextureFormat.BC7 or len(encoded) != SIZE[0] * SIZE[1]:
        raise ValueError("Over-frame texture compression failed")
    stream = texture.m_StreamData
    if stream and stream.path:
        name = stream.path.rsplit("/", 1)[-1]
        original_stream = env.file.files[name]
        if stream.offset != 0 or stream.size != len(original_stream.bytes):
            raise ValueError("Card texture shares an unsupported resource stream")
        new_stream = EndianBinaryReader(encoded)
        new_stream.flags = original_stream.flags
        env.file.files[name] = new_stream
        stream.size = len(encoded)
    else:
        texture.image_data = encoded

    texture.m_Width, texture.m_Height = SIZE
    texture.m_CompleteImageSize = len(encoded)
    texture.save()
    bundle = env.file.save(packer="lz4")

    reopened = UnityPy.load(bundle)
    final = find_texture(reopened, card_id)
    if (final.m_Width, final.m_Height) != SIZE or final.get_image_data() != encoded:
        raise ValueError("Reopened over-frame texture did not match")
    if list(reopened.container) != list(env.container) or final.m_TextureFormat != TextureFormat.BC7:
        raise ValueError("Over-frame bundle structure changed")
    return bundle


def gate_asset(bundle):
    matches = [obj.read() for obj in bundle.objects if obj.type.name == "TextAsset"
               and obj.peek_name() == GATE_NAME]
    if len(matches) != 1:
        raise ValueError("The bundle does not contain the Master Duel over-frame table")
    return matches[0]


def gate_records(asset):
    data = asset.m_Script.encode("utf-8", "surrogateescape")
    if len(data) % 4:
        raise ValueError("Unrecognized over-frame table")
    records = list(struct.iter_unpack("<HH", data))
    if len({trigger for trigger, _ in records}) != len(records) or not all(trigger for trigger, _ in records):
        raise ValueError("Invalid over-frame table entries")
    return records


def rewrite_gate(original, ids):
    bundle = UnityPy.load(original)
    asset = gate_asset(bundle)
    records = gate_records(asset)
    known = dict(records)
    additions = []
    for card_id in sorted(set(ids)):
        if not 0 < card_id < 65536 or (card_id in known and known[card_id] != card_id):
            raise ValueError(f"Cannot safely register card {card_id} over its official mapping")
        if card_id not in known:
            additions.append((card_id, card_id))
    if not additions:
        return original
    records += additions
    asset.m_Script = b"".join(struct.pack("<HH", *pair) for pair in records).decode("utf-8", "surrogateescape")
    asset.save()
    result = bundle.file.save(packer="lz4")
    if gate_records(gate_asset(UnityPy.load(result))) != records:
        raise ValueError("Reopened over-frame table did not match")
    return result

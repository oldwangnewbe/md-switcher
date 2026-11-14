"""Build per-account cut-ins from official alternatives and local MDPro3 animation assets."""

import hashlib
import json
import re
import zlib

from PIL import Image
import UnityPy

from generate_sky_striker import sha


CATALOG = "70/70e201b4"
TRIGGERS = "60/60c98f0d"
QUALITIES = ("SD", "HighEnd_HD")


def bundle_path(name):
    key = f"{zlib.crc32(name.encode()):08x}"
    return f"{key[:2]}/{key}"


def prefab_name(cid, quality):
    return f"Duel/Timeline/Duel/MonsterCutIn/tcg/P{cid}/{quality}/P{cid}"


def activation_name(cid, suffix=""):
    token = f"Ef{cid:05d}"
    return f"Duel/Timeline/Card/tcg/{token}/{token}{suffix}"


def activation_sources(cid, donor, entries):
    variants = [("", "")]
    if activation_name(cid, "_4x3") in entries:
        suffix = "_4x3" if activation_name(donor, "_4x3") in entries else ""
        variants.append(("_4x3", suffix))
    if activation_name(cid, "Op") in entries:
        suffix = "_Op" if activation_name(donor, "_Op") in entries else "Op"
        variants.append(("Op", suffix))
    return [(activation_name(cid, target), activation_name(donor, source))
            for target, source in variants]


def performance_index(cache, pro, index, names, same, mappings, records, catalog_path, trigger_path):
    # Verified against the official card textures. These prints are absent from cards_Lite.json.
    mappings = {3416: 52038442, 3898: 10443958, 23137: 34755995, 23487: 46986431,
                23488: 38033133, 23491: 83764722, **mappings}
    catalog = json.loads(catalog_cipher(catalog_path.read_bytes()))["informations"]
    entries = {row["assetName"]: row["dependencies"] for row in catalog}
    _, _, table = summon_trigger_table(trigger_path.read_bytes())
    triggers = {row["mrk"] for row in table["monsterCutinTable"]}
    referenced = {name for dependencies in entries.values() for name in dependencies}
    pro = pro / "MDPro3_Data/StandaloneWindows64"
    custom = pro / "MonsterCutin2"

    def prefabs(cid):
        return [prefab_name(cid, quality) for quality in QUALITIES]

    def available(paths):
        return all(path in entries and (hashed := bundle_path(path)) in index and (cache / hashed).is_file()
                   for path in paths)

    def assets_present(paths):
        pending = list(paths)
        seen = set()
        while pending:
            path = pending.pop()
            if path in seen:
                continue
            if not available([path]):
                return False
            seen.add(path)
            pending.extend(entries[path])
        return True

    def row(cid, artwork, kind, donor=None):
        result = {"cid": cid, "artworkID": artwork, "name": names[cid]}
        if kind in (1, 2, 3, 5):
            result["activationStyle"] = kind
        result["addsSummon"] = kind == 4
        if donor is not None:
            result["donor"] = donor
        return result

    results = {cid: {} for cid in records}
    for donor, cid in same.items():
        artwork = mappings.get(donor)
        card = records.get(cid)
        if not card or artwork not in {variant["id"] for variant in card["variants"]}:
            continue
        target = prefabs(cid)
        donor_paths = prefabs(donor)
        if cid in triggers and available(target) and not referenced.intersection(target):
            if assets_present(donor_paths):
                results[cid][artwork, False] = row(cid, artwork, 0, donor)
        elif cid not in triggers and not any(name in entries for name in target) and assets_present(donor_paths):
            results[cid][artwork, False] = row(cid, artwork, 4, donor)

        pairs = activation_sources(cid, donor, entries)
        targets, sources = zip(*pairs)
        if available(targets) and not referenced.intersection(targets) and assets_present(sources):
            kind = 5 if len(targets) == 3 else 3 if targets[-1].endswith("Op") else len(targets)
            results[cid][artwork, True] = row(cid, artwork, kind, donor)

    if custom.is_dir() and assets_present(prefabs(13668)):
        for cid, card in records.items():
            targets = prefabs(cid)
            base_artwork = card.get("originalArtworkID")
            if cid in triggers and available(targets) and not referenced.intersection(targets):
                kind = 0
            elif cid not in triggers and not any(name in entries for name in targets):
                kind = 4
            else:
                continue
            selected_artworks = {variant["id"] for variant in card["variants"]}
            # Also accept an exact local animation whose illustration is not installed,
            # e.g. the MDPro3-only outfit for Raye.
            if kind == 4:
                selected_artworks.update(card["codes"])
            for artwork in selected_artworks | ({base_artwork} if kind == 4 and base_artwork else set()):
                if (artwork, False) in results[cid] or not (custom / str(artwork)).is_file():
                    continue
                try:
                    custom_source(pro, artwork)
                except (ValueError, KeyError, OSError, AttributeError, EOFError):
                    continue
                results[cid][artwork, False] = row(cid, artwork, kind)
    return {cid: list(options.values()) for cid, options in results.items() if options}


def activation_bundle(original, donor, target_name, donor_name, dependencies):
    env = UnityPy.load(donor)
    target = UnityPy.load(original)
    donor_cab, = [key for key, value in env.file.files.items() if hasattr(value, "externals")]
    target_cab, = [key for key, value in target.file.files.items() if hasattr(value, "externals")]
    source_key, = env.container
    target_key, = target.container
    root = env.container[source_key]
    source_object = root.read()
    if (not source_key.endswith(donor_name.lower() + ".prefab") or
            not target_key.endswith(target_name.lower() + ".prefab") or
            source_object.m_Name != donor_name.rsplit("/", 1)[-1] or
            target.container[target_key].read().m_Name != target_name.rsplit("/", 1)[-1]):
        raise ValueError("发动演出预制件入口不匹配")

    asset, = [obj for obj in env.objects if obj.type.name == "AssetBundle"]
    data = asset.read_typetree()
    if not set(data["m_Dependencies"]).issubset(dependencies):
        raise ValueError("异画发动演出依赖与游戏索引不匹配")
    data["m_Name"] = bundle_path(target_name)
    if "m_AssetBundleName" in data:
        data["m_AssetBundleName"] = data["m_Name"]
    data["m_Container"] = [(target_key if key == source_key else key, ref) for key, ref in data["m_Container"]]
    asset.save_typetree(data)
    # Preserve internal object names because the donor's timeline binds to those names.
    source_object.m_Name = target_name.rsplit("/", 1)[-1]
    source_object.save()
    for obj in env.objects:
        if obj.type.name == "Texture2D":
            texture = obj.read()
            stream = texture.m_StreamData
            if stream and donor_cab in stream.path:
                stream.path = stream.path.replace(donor_cab, target_cab)
                texture.save()
    env.file.files = {key.replace(donor_cab, target_cab): value for key, value in env.file.files.items()}
    output = env.file.save(packer="lz4")
    rebuilt = UnityPy.load(output)
    if (list(rebuilt.container) != [target_key] or target_cab not in rebuilt.file.files or
            rebuilt.container[target_key].read().m_Name != source_object.m_Name):
        raise ValueError("发动演出重封装校验失败")
    return output


def catalog_cipher(data):
    # Master Duel's manifest keystream uses .NET Random with seed 855 and inextp=31.
    modulus = 2147483647
    state = [0] * 56
    state[55] = previous = 161803398 - 855
    value = 1
    for i in range(1, 55):
        position = i * 21 % 55
        state[position] = value
        value = (previous - value) % modulus
        previous = state[position]
    for _ in range(4):
        for i in range(1, 56):
            state[i] = (state[i] - state[1 + (i + 30) % 55]) % modulus
    i, j = 0, 31
    output = bytearray(data)
    for offset, byte in enumerate(data):
        i, j = i % 55 + 1, j % 55 + 1
        state[i] = (state[i] - state[j]) % modulus
        output[offset] = byte ^ (state[i] * 256 // modulus)
    return bytes(output)


def prefab_bundle(original, donor, relative, target_id, donor_id, dependencies):
    env = UnityPy.load(donor)
    old_name, new_name = f"P{donor_id}", f"P{target_id}"
    donor_cab, = [key for key, value in env.file.files.items() if hasattr(value, "externals")]
    # Give the copy the original target's serialized-file identity so the real
    # alternate print can still load its own prefab in the same game session.
    if original is None:
        target_cab = new_cab(relative)
    else:
        target_cab, = [key for key, value in UnityPy.load(original).file.files.items() if hasattr(value, "externals")]
    env.file.files = {key.replace(donor_cab, target_cab): value for key, value in env.file.files.items()}
    asset_bundle, = [obj for obj in env.objects if obj.type.name == "AssetBundle"]
    data = asset_bundle.read_typetree()
    if not set(data["m_Dependencies"]).issubset(dependencies):
        raise ValueError("Donor prefab references an asset missing from the catalog")
    data["m_Name"] = relative
    if "m_AssetBundleName" in data:
        data["m_AssetBundleName"] = relative
    data["m_Container"] = [(path.replace(old_name.lower(), new_name.lower()), asset)
                           for path, asset in data["m_Container"]]
    asset_bundle.save_typetree(data)
    root_found = False
    for obj in env.objects:
        if obj.type.name == "Texture2D":
            texture = obj.read()
            stream = texture.m_StreamData
            if stream and donor_cab in stream.path:
                stream.path = stream.path.replace(donor_cab, target_cab)
                texture.save()
        if obj.type.name not in ("GameObject", "Mesh") or old_name not in obj.peek_name():
            continue
        entry = obj.read()
        root_found |= obj.type.name == "GameObject" and entry.m_Name == old_name
        entry.m_Name = entry.m_Name.replace(old_name, new_name)
        entry.save()
    if not root_found:
        raise ValueError("Donor cut-in root not found")
    return env.file.save(packer="lz4")


def new_cab(logical):
    return "CAB-" + hashlib.md5(logical.encode(), usedforsecurity=False).hexdigest()


def summon_trigger_table(original):
    env = UnityPy.load(original)
    entry, = [obj for obj in env.objects
              if obj.type.name == "MonoBehaviour" and obj.peek_name() == "CardIndividualData"]
    return env, entry, entry.read_typetree()


def summon_triggers(original, additions):
    env, entry, data = summon_trigger_table(original)
    current = {row["mrk"] for row in data["monsterCutinTable"]}
    if current.intersection(additions):
        raise ValueError("部分卡片已有官方召唤演出，请核对游戏版本")
    if any(set(row) != {"mrk"} for row in data["monsterCutinTable"]):
        raise ValueError("游戏召唤登记格式已变化")
    data["monsterCutinTable"].extend({"mrk": cid} for cid in sorted(additions))
    entry.save_typetree(data)
    return env.file.save(packer="lz4")


def skeleton_renderer(objects):
    renderer, = [obj for obj in objects
                 if obj.type.name == "MonoBehaviour" and "skeletonDataAsset" in obj.read_typetree()]
    return renderer


def skeleton_transform(objects):
    return skeleton_renderer(objects).read().m_GameObject.read().m_Transform.deref()


def merge_atlas(atlas, textures, name):
    pages = re.split(r"(?m)^(\S[^\r\n]*\.png)\s*$", atlas.strip())[1:]
    sizes = [tuple(map(int, re.search(r"(?m)^size:\s*(\d+)\s*,\s*(\d+)", page).groups()))
             for page in pages[1::2]]
    width = sum(w for w, _ in sizes)
    height = max(h for _, h in sizes)
    scale = min(1, 4096 / max(width, height))
    image = Image.new("RGBA", (round(width * scale), round(height * scale)))
    sections = [f"{name}.png\nsize:{width},{height}\nfilter:Linear,Linear"]
    offset = 0
    for filename, content, (w, h) in zip(pages[::2], pages[1::2], sizes):
        header, body = re.split(r"(?m)^(?=[^:\r\n]+\r?$)", content.lstrip(), maxsplit=1)
        if offset == 0 and re.search(r"(?m)^pma:\s*true\s*$", header):
            sections[0] += "\npma:true"
        left, right = round(offset * scale), round((offset + w) * scale)
        page = textures[filename[:-4]].image.convert("RGBA")
        image.paste(page.resize((right - left, round(h * scale)), Image.Resampling.LANCZOS), (left, 0))
        for field in ("bounds", "xy"):
            body = re.sub(rf"(?m)^({field}:\s*)(\d+)", lambda match: match[1] + str(offset + int(match[2])), body)
        sections.append(body.strip())
        offset += w
    return "\n".join(sections) + "\n", image


def custom_source(pro, artwork_id):
    source = pro / f"MonsterCutin2/{artwork_id}"
    if not source.is_file():
        raise ValueError(f"找不到 MDPro3 的召唤素材 {artwork_id}")
    objects = UnityPy.load(source.read_bytes()).objects
    texts = {obj.peek_name(): obj.read().m_Script for obj in objects if obj.type.name == "TextAsset"}
    skeleton = json.loads(texts[str(artwork_id)])
    animations = skeleton["animations"]
    renderer = skeleton_renderer(objects)
    action_name = renderer.read_typetree().get("_animationName")
    action = animations.get(action_name)
    if action is None and len(animations) == 1:
        action = next(iter(animations.values()))
    if not action:
        raise ValueError(f"找不到 MDPro3 素材的召唤动作 {artwork_id}")
    # The template uses animation_kde. Keep the usual name for any fallback track.
    skeleton["animations"] = {"animation": action, "animation_kde": action}
    atlas, = [text for name, text in texts.items() if name.endswith(".atlas")]
    available_textures = {obj.peek_name(): obj for obj in objects if obj.type.name == "Texture2D"}
    page_names = [line.strip()[:-4] for line in atlas.splitlines() if line.strip().endswith(".png")]
    if not page_names or any(name not in available_textures for name in page_names):
        raise ValueError(f"MDPro3 召唤素材缺少图集贴图 {artwork_id}")
    textures = {name: available_textures[name].read() for name in page_names}
    placement = skeleton_transform(objects).read_typetree()
    return json.dumps(skeleton, separators=(",", ":")), atlas, textures, placement


def clone_custom(entries, read, original, add, pro, cid, artwork_id, adding=False):
    skeleton, atlas, textures, placement = custom_source(pro, artwork_id)
    template, replacement = "P13668", f"P{cid}"
    if len(textures) == 1:
        texture, = textures.values()
        atlas = atlas.replace(texture.m_Name + ".png", replacement + ".png")
        combined = None
    else:
        atlas, combined = merge_atlas(atlas, textures, replacement)
    prefabs = [prefab_name(13668, quality) for quality in QUALITIES]
    dependencies = {dep for name in prefabs for dep in entries[name]["dependencies"]}
    cloned = {
        name: name.replace(template, replacement).replace(f"/{replacement}/", f"/{replacement}/MDSwitcher/")
        for name in dependencies if f"/{template}/" in name
    }
    cloned.update({name: prefab_name(cid, quality) for name, quality in zip(prefabs, QUALITIES)})
    bundles = {name: UnityPy.load(read(bundle_path(name))) for name in sorted(cloned)}
    cabs = {}
    originals = {}
    for name, env in bundles.items():
        cab, = [key for key in env.file.files if not key.endswith(".resS")]
        target = cloned[name]
        if name in prefabs and not adding:
            originals[name] = original(bundle_path(target))
            cabs[cab], = UnityPy.load(originals[name]).file.files
        else:
            cabs[cab] = new_cab(target)
    paths = {bundle_path(old): bundle_path(new) for old, new in cloned.items()}
    for path in sorted(dependencies - cloned.keys()):
        read(bundle_path(path))

    for name, env in bundles.items():
        new_name = cloned[name]
        target_path = bundle_path(new_name)
        if (new_name in entries) != (name in originals):
            raise ValueError(f"大师决斗的演出资源已变化，请检查版本 P{cid}")
        if name in prefabs and any(new_name in row["dependencies"] for row in entries.values()):
            raise ValueError(f"Cannot replace a prefab shared with another resource: P{cid}")
        cab, = [key for key in env.file.files if key in cabs]
        serialized = env.file.files[cab]
        if name in prefabs:
            # Spine coordinates are local to the animated object. Keep the
            # source prefab's framing while retaining the game's camera and timeline.
            transform = skeleton_transform(env.objects)
            data = transform.read_typetree()
            for field in ("m_LocalPosition", "m_LocalScale", "m_LocalRotation"):
                data[field] = placement[field]
            transform.save_typetree(data)
        for external in serialized.externals:
            external.path = "/".join(cabs.get(part, part) for part in external.path.split("/"))
        for obj in env.objects:
            kind = obj.type.name
            if kind == "AssetBundle":
                data = obj.read_typetree()
                data["m_Name"] = target_path
                if "m_AssetBundleName" in data:
                    data["m_AssetBundleName"] = target_path
                data["m_Container"] = [(path.replace(template.lower(), replacement.lower()), pointer)
                                       for path, pointer in data["m_Container"]]
                data["m_Dependencies"] = [paths.get(path, path) for path in data["m_Dependencies"]]
                obj.save_typetree(data)
            elif kind in ("GameObject", "Mesh", "Material", "MonoBehaviour") and template in obj.peek_name():
                item = obj.read()
                item.m_Name = item.m_Name.replace(template, replacement)
                item.save()
            elif kind == "TextAsset" and obj.peek_name() in (template + "JS", template + ".atlas"):
                item = obj.read()
                item.m_Script = skeleton if item.m_Name.endswith("JS") else atlas
                item.m_Name = item.m_Name.replace(template, replacement)
                item.save()
            elif kind == "Texture2D":
                item = obj.read()
                if item.m_Name != template:
                    raise ValueError("Unexpected texture in the cut-in template")
                item.m_Name = replacement
                if combined is None:
                    item.m_Width, item.m_Height = texture.m_Width, texture.m_Height
                    item.m_TextureFormat, item.m_MipCount = texture.m_TextureFormat, texture.m_MipCount
                    item.image_data = texture.get_image_data()
                else:
                    item.set_image(combined, target_format=4, mipmap_count=1)
                item.m_CompleteImageSize = len(item.image_data)
                item.m_StreamData.path, item.m_StreamData.offset, item.m_StreamData.size = "", 0, 0
                item.save()
        env.file.files = {cabs[cab]: serialized}
        entries[new_name] = {"assetName": new_name, "dependencies": [
            cloned.get(dep, dep) for dep in entries[name]["dependencies"]
        ]}
        add(target_path, originals.get(name), env.file.save(packer="lz4"), new_name)


def make_summon_pack(cache, originals, output, pro_directory, cards):
    official = {row["assetName"]: row for row in json.loads((cache / "86/868ffd0e").read_bytes())["informations"]}
    verified = set()

    def verify(path, data):
        entry = official.get(path)
        if not entry or entry["bytes"] != len(data) or entry["crc"] != sha(data):
            raise ValueError(f"Original game resource missing or changed: {path}")

    def original(path):
        data = (originals / path.split("/")[-1]).read_bytes()
        verify(path, data)
        return data

    def read(path):
        if (originals / path.split("/")[-1]).is_file():
            return original(path)
        data = (cache / path).read_bytes()
        verify(path, data)
        return data

    pack = []

    def add(path, before, after, name):
        if before is None and path in official:
            raise ValueError(f"New cut-in bundle would overwrite an official resource: {path}")
        identifier = int(path.split("/")[-1], 16)
        (output / f"{identifier}.bundle").write_bytes(after)
        pack.append({"name": name, "path": path, "originalSHA256": sha(before) if before is not None else None,
                     "variants": [{"id": identifier, "sha256": sha(after)}]})

    catalog_bytes = original(CATALOG)
    catalog = json.loads(catalog_cipher(catalog_bytes))
    entries = {row["assetName"]: row for row in catalog["informations"]}
    referenced = {name for row in entries.values() for name in row["dependencies"]}
    pro = pro_directory / "MDPro3_Data/StandaloneWindows64"
    summons = [(cid, artwork_id, donor) for cid, artwork_id, donor, kind in cards if kind == 0]
    additions = [(cid, artwork_id, donor) for cid, artwork_id, donor, kind in cards if kind == 4]
    if len({(cid, kind in (0, 4)) for cid, _, _, kind in cards}) != len(cards):
        raise ValueError("每张卡最多选择一种召唤演出和一种发动演出")
    if additions:
        trigger_bytes = original(TRIGGERS)
        updated_triggers = summon_triggers(trigger_bytes, {cid for cid, _, _ in additions})
        for cid, artwork_id, donor in additions:
            if not donor:
                clone_custom(entries, read, original, add, pro, cid, artwork_id, adding=True)
        add(TRIGGERS, trigger_bytes, updated_triggers, "新增召唤演出触发配置")
    for cid, _, _ in summons:
        if any(prefab_name(cid, quality) not in entries for quality in QUALITIES):
            raise ValueError(f"P{cid} 缺少原版召唤演出，无法替换")
    for cid, artwork_id, donor in summons:
        if not donor:
            clone_custom(entries, read, original, add, pro, cid, artwork_id)
    for cid, donor, adding in ([(cid, donor, False) for cid, _, donor in summons if donor] +
                               [(cid, donor, True) for cid, _, donor in additions if donor]):
        for quality in QUALITIES:
            target_name = prefab_name(cid, quality)
            donor_name = prefab_name(donor, quality)
            if (target_name in entries) == adding:
                raise ValueError(f"大师决斗的演出资源已变化，请检查版本 P{cid}")
            if target_name in referenced:
                raise ValueError(f"Cannot replace a prefab shared with another resource: P{cid} {quality}")
            target_path, donor_path = map(bundle_path, (target_name, donor_name))
            donor_entry = entries[donor_name]
            dependencies = {bundle_path(name) for name in donor_entry["dependencies"]}
            for path in sorted(dependencies - verified):
                read(path)
                verified.add(path)
            donor_data = read(donor_path)
            before = None if adding else original(target_path)
            after = prefab_bundle(before, donor_data, target_path, cid, donor, dependencies)
            entries[target_name] = {"assetName": target_name, "dependencies": donor_entry["dependencies"]}
            add(target_path, before, after, f"P{cid} {quality}")
    for cid, _, donor, kind in cards:
        if kind in (0, 4):
            continue
        if kind not in (1, 2, 3, 5) or not donor or cid == donor:
            raise ValueError("发动演出配置无效")
        expected = {1: [""], 2: ["", "_4x3"], 3: ["", "Op"], 5: ["", "_4x3", "Op"]}
        pairs = activation_sources(cid, donor, entries)
        if [target for target, _ in pairs] != [activation_name(cid, suffix) for suffix in expected[kind]]:
            raise ValueError(f"大师决斗的发动演出资源已变化 Ef{cid:05d}")
        for target_name, source_name in pairs:
            if target_name not in entries or any(target_name in row["dependencies"] for row in entries.values()):
                raise ValueError(f"无法单独替换发动演出 {target_name}")
            if source_name not in entries:
                raise ValueError(f"找不到异画版的配套发动演出 {source_name}")
            source_entry = entries[source_name]
            pending = list(source_entry["dependencies"])
            seen = set()
            while pending:
                dependency = pending.pop()
                if dependency in seen:
                    continue
                if dependency not in entries:
                    raise ValueError(f"缺少发动演出依赖 {dependency}")
                read(bundle_path(dependency))
                seen.add(dependency)
                pending.extend(entries[dependency]["dependencies"])
            target_path = bundle_path(target_name)
            before = original(target_path)
            after = activation_bundle(before, read(bundle_path(source_name)), target_name, source_name,
                                      {bundle_path(name) for name in seen})
            entries[target_name] = {**entries[target_name], "dependencies": source_entry["dependencies"]}
            add(target_path, before, after, target_name.rsplit("/", 1)[-1])
    catalog["informations"] = list(entries.values())
    serialized = json.dumps(catalog, ensure_ascii=False, separators=(",", ":")).encode()
    add(CATALOG, catalog_bytes, catalog_cipher(serialized), "卡片演出资源依赖")
    (output / "manifest.json").write_text(json.dumps(pack, ensure_ascii=False), encoding="utf-8")

"""Build per-account cut-ins from official alternatives and local MDPro3 animation assets."""

import hashlib
import json
import zlib

import UnityPy

from generate_sky_striker import sha


CATALOG = "70/70e201b4"
QUALITIES = ("SD", "HighEnd_HD")


def bundle_path(name):
    key = f"{zlib.crc32(name.encode()):08x}"
    return f"{key[:2]}/{key}"


def prefab_name(cid, quality):
    return f"Duel/Timeline/Duel/MonsterCutIn/tcg/P{cid}/{quality}/P{cid}"


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


def custom_source(pro, artwork_id):
    source = pro / f"MonsterCutin2/{artwork_id}"
    if not source.is_file():
        raise ValueError(f"找不到 MDPro3 的异画召唤素材 {artwork_id}")
    objects = UnityPy.load(source.read_bytes()).objects
    texts = {obj.peek_name(): obj.read().m_Script for obj in objects if obj.type.name == "TextAsset"}
    skeleton = json.loads(texts[str(artwork_id)])
    animations = skeleton["animations"]
    action = animations["move"] if "move" in animations else animations["animation"]
    # The template uses animation_kde. Keep the usual name for any fallback track.
    skeleton["animations"] = {"animation": action, "animation_kde": action}
    texture, = [obj.read() for obj in objects if obj.type.name == "Texture2D"]
    atlas = texts[texture.m_Name + ".atlas"]
    if not atlas.lstrip().startswith(texture.m_Name + ".png"):
        raise ValueError(f"无法识别 MDPro3 图集 {artwork_id}")
    return json.dumps(skeleton, separators=(",", ":")), atlas, texture


def clone_custom(entries, read, original, add, pro, cid, artwork_id):
    skeleton, atlas, texture = custom_source(pro, artwork_id)
    template, replacement = "P13668", f"P{cid}"
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
        if name in prefabs:
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
            elif kind in ("GameObject", "Mesh") and template in obj.peek_name():
                item = obj.read()
                item.m_Name = item.m_Name.replace(template, replacement)
                item.save()
            elif kind == "TextAsset" and obj.peek_name() in (template + "JS", template + ".atlas"):
                item = obj.read()
                item.m_Script = skeleton if item.m_Name.endswith("JS") else atlas.replace(texture.m_Name + ".png", replacement + ".png")
                item.m_Name = item.m_Name.replace(template, replacement)
                item.save()
            elif kind == "Texture2D":
                item = obj.read()
                if item.m_Name != template:
                    raise ValueError("Unexpected texture in the cut-in template")
                item.m_Name = replacement
                item.m_Width, item.m_Height = texture.m_Width, texture.m_Height
                item.m_TextureFormat, item.m_MipCount = texture.m_TextureFormat, texture.m_MipCount
                item.image_data = texture.get_image_data()
                item.m_CompleteImageSize = len(item.image_data)
                item.m_StreamData.path, item.m_StreamData.offset, item.m_StreamData.size = "", 0, 0
                item.save()
        env.file.files = {cabs[cab]: serialized}
        entries[new_name] = {"assetName": new_name, "dependencies": [
            cloned.get(dep, dep) for dep in entries[name]["dependencies"]
        ]}
        add(target_path, originals.get(name), env.file.save(packer="lz4"), new_name)


def native_source(pro, artwork_id, donor, names, entries):
    folder = pro / f"MonsterCutin/{artwork_id}"
    if not folder.is_dir():
        raise ValueError(f"找不到 MDPro3 的异画演出 {artwork_id}")
    candidates = set(names)
    candidates.update(dep for name in names for dep in entries[name]["dependencies"]
                      if f"/P{donor}/" in dep and dep.endswith("JS"))
    if any((folder / bundle_path(name).split("/")[-1]).is_file() for name in candidates):
        return
    for file in folder.iterdir():
        if file.is_file() and any(obj.type.name == "TextAsset" and obj.peek_name() == f"P{donor}JS"
                                  for obj in UnityPy.load(file.read_bytes()).objects):
            return
    raise ValueError(f"MDPro3 素材与大师决斗异画 P{donor} 的编号不匹配")


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
    pro = pro_directory / "MDPro3_Data/StandaloneWindows64"
    for cid, _, _ in cards:
        if any(prefab_name(cid, quality) not in entries for quality in QUALITIES):
            raise ValueError(f"P{cid} 缺少原版召唤演出，无法替换")
    for cid, artwork_id, donor in cards:
        if not donor:
            clone_custom(entries, read, original, add, pro, cid, artwork_id)
    for cid, artwork_id, donor in cards:
        if not donor:
            continue
        native_source(pro, artwork_id, donor, [prefab_name(donor, q) for q in QUALITIES], entries)
        for quality in QUALITIES:
            target_name = prefab_name(cid, quality)
            donor_name = prefab_name(donor, quality)
            if any(target_name in row["dependencies"] for row in catalog["informations"]):
                raise ValueError(f"Cannot replace a prefab shared with another resource: P{cid} {quality}")
            target_path, donor_path = map(bundle_path, (target_name, donor_name))
            donor_entry = entries[donor_name]
            dependencies = {bundle_path(name) for name in donor_entry["dependencies"]}
            for path in sorted(dependencies - verified):
                verify(path, (cache / path).read_bytes())
                verified.add(path)
            donor_data = (cache / donor_path).read_bytes()
            verify(donor_path, donor_data)
            before = original(target_path)
            after = prefab_bundle(before, donor_data, target_path, cid, donor, dependencies)
            entries[target_name] = {"assetName": target_name, "dependencies": donor_entry["dependencies"]}
            add(target_path, before, after, f"P{cid} {quality}")
    catalog["informations"] = list(entries.values())
    serialized = json.dumps(catalog, ensure_ascii=False, separators=(",", ":")).encode()
    add(CATALOG, catalog_bytes, catalog_cipher(serialized), "召唤动画资源依赖")
    (output / "manifest.json").write_text(json.dumps(pack, ensure_ascii=False), encoding="utf-8")

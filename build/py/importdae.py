"""Imports a Blender Collada export into the mod: fixes it up for the game and writes the mod's DAE.

    python3 build/py/importdae.py carburettor <path to the Blender export .dae>

What the game needs, and what this does to every mesh (one node = one mesh):
  - The hierarchy is flattened (parents in Blender are fine: the exporter writes world matrices).
  - Static meshes (flexbodies): the game ignores a flexbody's node transform, so their vertices are written in car
    coordinates (node matrix applied, plus "move") and the node matrix becomes the identity.
  - Moving meshes (props, listed in "props"): the origin stays where it is in Blender (the pivot the prop turns
    about) and is moved by "move"; any turn of the node is applied to the vertices.
  - Materials get the mod's unique names ("materials"): the game finds materials by name across all mods.
  - Highlight meshes: a mesh named <mesh>_highlight is the shell that lights up when <mesh> is pointed at (material
    bug_highlight, slightly larger than the mesh). For meshes in "makeHighlight" the shell is made here: a copy of
    the mesh, every vertex pushed out along its normal by the given distance (m). Shells of moving meshes are moved
    by the same prop as their mesh (jbeam), so they must have the same origin. A shell may also stand alone and light
    up a larger area ("standaloneShells", e.g. engine_highlight).
  - "rename" fixes node names, "scale" applies a scale the exporter dropped (the node's vertices are multiplied
    first).

It checks the export and prints what looks wrong (a mesh far too big, a node turned or scaled, a shell whose origin
isn't its mesh's, a shell without a mesh, an unknown material). Fix those in Blender if you can and export again.
"""

import copy
import sys
import xml.etree.ElementTree as ET

C = "http://www.collada.org/2005/11/COLLADASchema"
NS = {"c": C}
HL_SUFFIX = "_highlight"
HL_MATERIAL = "bug_highlight"

MODELS = {
    # the single Solex carburettor (bug_intake, bug_intake_D in frame/bug.engine.*.jbeam)
    "carburettor": {
        "dst": "bug/vehicles/bug/components/engine/Carburettor.dae",
        # Blender → car: onto the intake manifold flange, where the old carburettor sat
        "move": (0.0, 0.050, 0.263),
        "rename": {"fule_line": "carb_fuel_line", "fule_line_clamps": "carb_fuel_line_clamps"},
        "scale": {},
        # props in the jbeam (each turns about / moves from its origin), with their highlight shells
        "props": ["carb_throttle_lever", "carb_throttle_lever_highlight", "carb_idle_screw", "carb_idle_screw_highlight",
                  "carb_accelerator_rod", "carb_stepped_cam", "carb_operating_lever", "carb_throttle_cable",
                  "carb_choke", "carb_choke_highlight", "carb_choke_retaining_ring",
                  "carb_choke_retaining_ring_screw_top", "carb_choke_retaining_ring_screw_top_highlight",
                  "carb_choke_retaining_ring_screw_left", "carb_choke_retaining_ring_screw_left_highlight",
                  "carb_choke_retaining_ring_screw_right", "carb_choke_retaining_ring_screw_right_highlight"],
        "materials": {
            "brass": "bug_carb_brass",
            "casted_steel": "bug_carb_cast_steel",
            "white_plastic": "bug_carb_white_plastic",
            "aluminum": "bug_carb_aluminum",
            "aluminum.002": "bug_carb_aluminum",
            "black_plastic.005": "bug_carb_black_plastic",
            "stainless-steel": "bug_carb_stainless",
            "Engine.001": "bug_carb_fuel_hose",
            "Metal_Black": "bug_carb_spring",
            "bug_highlight": HL_MATERIAL,
        },
        # a mesh's own material instead of the shared one: {"<mesh>": {"<mod name>": "<mod name for this mesh>"}}
        "meshMaterials": {},
        # shells made here from whole meshes: {"<mesh>": push in m}, e.g. {"carb_body": 0.0005}
        "makeHighlight": {"carb_choke": 0.0005},
        # shells that light up more than one part (no mesh of their own name)
        "standaloneShells": ["engine_highlight"],
        # meshes the jbeams use: the DAE isn't written if one is missing (an export of only the selected objects)
        "required": ["carb_body", "carb_plug_main_jet", "carb_choke", "carb_choke_retaining_ring",
                     "carb_choke_retaining_ring_screw_top", "carb_choke_retaining_ring_screw_left",
                     "carb_choke_retaining_ring_screw_right", "carb_spring_arm", "carb_spring_arm_screw",
                     "carb_throttle_spring", "carb_fuel_line", "carb_fuel_line_clamps",
                     "carb_throttle_lever", "carb_idle_screw", "carb_accelerator_rod", "carb_stepped_cam",
                     "carb_operating_lever", "carb_throttle_cable",
                     "engine_highlight", "carb_idle_screw_highlight", "carb_throttle_lever_highlight",
                     "carb_choke_retaining_ring_screw_top_highlight", "carb_choke_retaining_ring_screw_left_highlight",
                     "carb_choke_retaining_ring_screw_right_highlight", "carb_spring_arm_highlight",
                     "carb_spring_arm_screw_highlight", "carb_choke_highlight"],
        # every mesh must lie within this box (car coordinates, m) after the import: the engine (engine_highlight)
        "bounds": ((-0.5, 1.2, 0.2), (0.5, 2.0, 1.0)),
    },
}


def floats(el):
    return [float(x) for x in el.text.split()]


def fmt(vals):
    return " ".join("%.7g" % v for v in vals)


def mat_mul_point(m, v):
    return [m[0] * v[0] + m[1] * v[1] + m[2] * v[2] + m[3],
            m[4] * v[0] + m[5] * v[1] + m[6] * v[2] + m[7],
            m[8] * v[0] + m[9] * v[1] + m[10] * v[2] + m[11]]


def mat_mul_dir(m, v):
    return [m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
            m[4] * v[0] + m[5] * v[1] + m[6] * v[2],
            m[8] * v[0] + m[9] * v[1] + m[10] * v[2]]


def unit(v):
    l = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) ** 0.5
    return [x / l for x in v] if l > 1e-12 else [0.0, 0.0, 1.0]


def is_identity3(m):
    return all(abs(a - b) < 1e-6 for a, b in zip([m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]],
                                                 [1, 0, 0, 0, 1, 0, 0, 0, 1]))


class Mesh:
    def __init__(self, geo):
        self.geo = geo
        mesh = geo.find("c:mesh", NS)
        self.mesh = mesh
        srcs = {s.get("id"): s for s in mesh.findall("c:source", NS)}
        pid = mesh.find("c:vertices/c:input[@semantic='POSITION']", NS).get("source")[1:]
        self.pos_el = srcs[pid].find("c:float_array", NS)
        self.nor_el = None
        for tri in mesh.findall("c:triangles", NS):
            n = tri.find("c:input[@semantic='NORMAL']", NS)
            if n is not None:
                self.nor_el = srcs[n.get("source")[1:]].find("c:float_array", NS)
                break

    def positions(self):
        return floats(self.pos_el)

    def set_positions(self, p):
        self.pos_el.text = fmt(p)

    def normals(self):
        return floats(self.nor_el) if self.nor_el is not None else None

    def set_normals(self, n):
        if self.nor_el is not None:
            self.nor_el.text = fmt(n)

    def corners(self):
        """per triangle corner: (position index, normal index or None)"""
        out = []
        for tri in self.mesh.findall("c:triangles", NS):
            inputs = tri.findall("c:input", NS)
            stride = max(int(i.get("offset")) for i in inputs) + 1
            voff = int(tri.find("c:input[@semantic='VERTEX']", NS).get("offset"))
            nin = tri.find("c:input[@semantic='NORMAL']", NS)
            noff = int(nin.get("offset")) if nin is not None else None
            idx = [int(x) for x in tri.find("c:p", NS).text.split()]
            for k in range(0, len(idx), stride):
                out.append((idx[k + voff], idx[k + noff] if noff is not None else None))
        return out


def push_out(m, dist):
    """moves every vertex out along its normal (averaged over all vertices at the same place, so the shell doesn't
    tear open at hard edges)"""
    p = m.positions()
    n = m.normals()
    acc = {}
    key_of = []
    for i in range(0, len(p), 3):
        key_of.append((round(p[i] * 1e6), round(p[i + 1] * 1e6), round(p[i + 2] * 1e6)))
    for vi, ni in m.corners():
        if n is not None and ni is not None:
            d = n[ni * 3:ni * 3 + 3]
        else:
            continue
        a = acc.setdefault(key_of[vi], [0.0, 0.0, 0.0])
        a[0] += d[0]
        a[1] += d[1]
        a[2] += d[2]
    out = list(p)
    for i in range(len(key_of)):
        d = unit(acc.get(key_of[i], [0.0, 0.0, 0.0]))
        if key_of[i] not in acc:
            continue
        out[i * 3] += d[0] * dist
        out[i * 3 + 1] += d[1] * dist
        out[i * 3 + 2] += d[2] * dist
    m.set_positions(out)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in MODELS:
        print(__doc__)
        print("models: " + ", ".join(MODELS))
        sys.exit(1)
    spec = MODELS[sys.argv[1]]
    ET.register_namespace("", C)
    tree = ET.parse(sys.argv[2])
    root = tree.getroot()
    problems = []

    # materials: mod names (several Blender materials may become one)
    lib_mats = root.find("c:library_materials", NS)
    mat_name = {}   # material id → new name
    for mat in list(lib_mats):
        old = mat.get("name")
        new = spec["materials"].get(old)
        if new is None:
            problems.append("material %r has no mod name (add it to \"materials\")" % old)
            new = old
        mat_name[mat.get("id")] = new
    effect_of = {}
    for mat in list(lib_mats):
        new = mat_name[mat.get("id")]
        if new in effect_of:
            lib_mats.remove(mat)
        else:
            effect_of[new] = mat.find("c:instance_effect", NS).get("url")
            mat.set("id", new)
            mat.set("name", new)

    def add_material(name):
        if name in effect_of:
            return
        el = ET.SubElement(lib_mats, "{%s}material" % C, {"id": name, "name": name})
        ET.SubElement(el, "{%s}instance_effect" % C, {"url": next(iter(effect_of.values()))})
        effect_of[name] = True

    lib_geo = root.find("c:library_geometries", NS)
    geos = {g.get("id"): g for g in lib_geo.findall("c:geometry", NS)}
    scene = root.find(".//c:visual_scene", NS)
    move = spec["move"]
    props = set(spec["props"])
    used_geo = set()
    nodes = {}
    lo, hi = spec["bounds"]

    # flatten: the exporter writes every node's world matrix, also under a parent, but the game would add the
    # parent's on top
    parent_of = {ch: par for par in scene.iter() for ch in par}
    for node in list(scene.iter("{%s}node" % C)):
        par = parent_of[node]
        if par is not scene:
            par.remove(node)
            scene.append(node)

    for node in list(scene.iter("{%s}node" % C)):
        name = node.get("name")
        name = spec["rename"].get(name, name)
        node.set("id", name)
        node.set("name", name)
        nodes[name] = node
        mel = node.find("c:matrix", NS)
        m = floats(mel)
        ig = node.find("c:instance_geometry", NS)
        gid = ig.get("url")[1:]
        geo = geos[gid]
        if gid in used_geo:   # shared by two nodes: give this one its own copy
            geo = copy.deepcopy(geo)
            gid = gid + "_" + name
            geo.set("id", gid)
            lib_geo.append(geo)
            ig.set("url", "#" + gid)
        used_geo.add(gid)
        geo.set("name", name)
        if not is_identity3(m) and name not in spec["scale"]:
            problems.append("%s: its node is turned or scaled (rotation / scale not applied in Blender); "
                            "applied here" % name)
        s = spec["scale"].get(name, 1.0)
        mesh = Mesh(geo)
        p = mesh.positions()
        n = mesh.normals()
        if name in props:
            rot = [m[0], m[1], m[2], 0, m[4], m[5], m[6], 0, m[8], m[9], m[10], 0]
            p2 = []
            for i in range(0, len(p), 3):
                p2 += mat_mul_point(rot, [p[i] * s, p[i + 1] * s, p[i + 2] * s])
            origin = (m[3] + move[0], m[7] + move[1], m[11] + move[2])
            mel.text = fmt([1, 0, 0, origin[0], 0, 1, 0, origin[1], 0, 0, 1, origin[2], 0, 0, 0, 1])
            world = [p2[i] + origin[i % 3] for i in range(len(p2))]
        else:
            p2 = []
            for i in range(0, len(p), 3):
                q = mat_mul_point(m, [p[i] * s, p[i + 1] * s, p[i + 2] * s])
                p2 += [q[0] + move[0], q[1] + move[1], q[2] + move[2]]
            mel.text = fmt([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
            world = p2
        mesh.set_positions(p2)
        if n is not None:
            n2 = []
            for i in range(0, len(n), 3):
                n2 += unit(mat_mul_dir(m, n[i:i + 3]))
            mesh.set_normals(n2)
        for k in range(3):
            vals = world[k::3]
            if vals and (min(vals) < lo[k] or max(vals) > hi[k]):
                problems.append("%s: reaches %.3f … %.3f m in %s, outside the model's box (wrong scale or place?)"
                                % (name, min(vals), max(vals), "xyz"[k]))
                break
        # materials of this node
        per_mesh = spec.get("meshMaterials", {}).get(name, {})
        for im in ig.iterfind(".//c:instance_material", NS):
            new = mat_name.get(im.get("target")[1:], im.get("target")[1:])
            new = per_mesh.get(new, new)
            add_material(new)
            im.set("target", "#" + new)
        if name.endswith(HL_SUFFIX):
            targets = {im.get("target")[1:] for im in ig.iterfind(".//c:instance_material", NS)}
            if targets != {HL_MATERIAL}:
                problems.append("%s: a highlight shell must only use the material %s (has %s)"
                                % (name, HL_MATERIAL, ", ".join(sorted(targets))))

    # highlight shells made here
    for base, dist in spec.get("makeHighlight", {}).items():
        hl = base + HL_SUFFIX
        if hl in nodes:
            problems.append("%s exists in the export: not made here (remove it from \"makeHighlight\")" % hl)
            continue
        bnode = nodes[base]
        bgeo = geos[bnode.find("c:instance_geometry", NS).get("url")[1:]]
        geo = copy.deepcopy(bgeo)
        for el in geo.iter():   # ids inside the copy must be unique in the file
            if el.get("id"):
                el.set("id", el.get("id") + HL_SUFFIX)
            for attr in ("source", "url"):
                if el.get(attr, "").startswith("#"):
                    el.set(attr, el.get(attr) + HL_SUFFIX)
        gid = hl + "-mesh"
        geo.set("id", gid)
        geo.set("name", hl)
        for tri in geo.iterfind(".//c:triangles", NS):
            tri.set("material", "hl")
        lib_geo.append(geo)
        push_out(Mesh(geo), dist)
        node = ET.SubElement(scene, "{%s}node" % C, {"id": hl, "name": hl, "type": "NODE"})
        ET.SubElement(node, "{%s}matrix" % C, {"sid": "transform"}).text = bnode.find("c:matrix", NS).text
        ig = ET.SubElement(node, "{%s}instance_geometry" % C, {"url": "#" + gid})
        tc = ET.SubElement(ET.SubElement(ig, "{%s}bind_material" % C), "{%s}technique_common" % C)
        ET.SubElement(tc, "{%s}instance_material" % C, {"symbol": "hl", "target": "#" + HL_MATERIAL})
        add_material(HL_MATERIAL)
        nodes[hl] = node
        print("made %s (%.1f mm out)" % (hl, dist * 1000))

    # every shell needs its mesh, at the same origin
    for name, node in nodes.items():
        if not name.endswith(HL_SUFFIX) or name in spec.get("standaloneShells", []):
            continue
        base = name[:-len(HL_SUFFIX)]
        if base not in nodes:
            problems.append("%s: no mesh %s for it" % (name, base))
            continue
        a, b = floats(node.find("c:matrix", NS)), floats(nodes[base].find("c:matrix", NS))
        if any(abs(a[i] - b[i]) > 1e-6 for i in (3, 7, 11)):
            problems.append("%s: its origin isn't the origin of %s (a moving shell would turn about another point)"
                            % (name, base))
        if (name in props) != (base in props):
            problems.append("%s and %s: one is a prop, the other not (list both in \"props\")" % (name, base))

    missing = [n for n in spec.get("required", []) if n not in nodes]
    if missing:
        print("Not written: the export lacks meshes the jbeams use (exported only the selected objects?):")
        for n in missing:
            print("  - " + n)
        sys.exit(1)

    ET.indent(tree, space="  ")
    tree.write(spec["dst"], encoding="utf-8", xml_declaration=True)
    print("wrote %s: %d meshes" % (spec["dst"], len(nodes)))
    for name in sorted(nodes):
        print("  %s%s" % (name, " (prop)" if name in props else ""))
    if problems:
        print("\nCheck in Blender:")
        for p in problems:
            print("  - " + p)


if __name__ == "__main__":
    main()

// Figma Plugin API script: turns the SVGs run.sh produced (uploaded onto the Icons page) into
// variants of the `icon` component set. Run it through the Figma MCP's `use_figma` tool, or
// paste it into a plugin console. It is safe to re-run: existing variants are rebuilt in place
// (same node IDs, so instances stay linked) and new symbols are added.
//
// An uploaded SVG arrives as a frame named after the file, whose vectors are named
// "<symbol>|<layer>|<opacity>" (see pipeline.py). Opacity 0 is a knockout, between 0 and 1 a
// hierarchical layer; both are cut out of the layers beneath them.

const PAGE_ID = "897:301"; // ⮑ Icons
const SET_ID = "235:325"; // the `icon` component set
const FILL_VARIABLE_ID = "VariableID:9:5"; // Theme › color/primary
const ONLY = null; // e.g. (name) => name < "m" to split a large run across two calls

const page = await figma.getNodeByIdAsync(PAGE_ID);
await figma.setCurrentPageAsync(page);
const set = await figma.getNodeByIdAsync(SET_ID);
const fill = await figma.variables.getVariableByIdAsync(FILL_VARIABLE_ID);

const isUpload = (n) =>
    n.type === "FRAME" && n.children.length > 0 &&
    n.children.every((v) => v.type === "VECTOR" && v.name.split("|").length === 3);
const uploads = page.children.filter(isUpload).filter((f) => !ONLY || ONLY(f.name));
const existing = Object.fromEntries(set.children.map((c) => [c.name.replace("SF Symbol Name=", ""), c]));
const overlaps = (a, b) => {
    const p = a.absoluteBoundingBox, q = b.absoluteBoundingBox;
    return p.x < q.x + q.width && q.x < p.x + p.width && p.y < q.y + q.height && q.y < p.y + p.height;
};
// Boolean operations have no constraints of their own; their vectors carry them.
const scaleWithInstance = (n) => {
    if ("constraints" in n) n.constraints = { horizontal: "SCALE", vertical: "SCALE" };
    if (n.type === "BOOLEAN_OPERATION") n.children.forEach(scaleWithInstance);
};

const rebuilt = [], added = [];
for (const frame of uploads) {
    const name = frame.name, width = frame.width, height = frame.height;
    const layers = [...frame.children]
        .map((v) => { const [, idx, op] = v.name.split("|"); return { node: v, idx: +idx, op: +op }; })
        .sort((a, b) => a.idx - b.idx);
    const kept = [];
    for (const layer of layers) {
        if (layer.op < 0.97) {
            for (const below of kept) {
                if (!overlaps(below.node, layer.node)) continue;
                const cutter = layer.node.clone();
                frame.appendChild(cutter);
                below.node = figma.subtract([below.node, cutter], frame);
            }
            if (layer.op <= 0.03) { layer.node.remove(); continue; }
        }
        kept.push(layer);
    }
    for (const k of kept) {
        k.node.fills = [figma.variables.setBoundVariableForPaint(
            { type: "SOLID", color: { r: 1, g: 1, b: 1 } }, "color", fill)];
        // setBoundVariableForPaint drops paint opacity, so partial layers use node opacity.
        k.node.opacity = k.op < 0.97 ? k.op : 1;
        k.node.name = `layer ${k.idx}` + (k.op < 0.97 ? ` (${Math.round(k.op * 100)}%)` : "");
        scaleWithInstance(k.node);
    }
    frame.name = "iconFrame";
    frame.fills = [];
    frame.clipsContent = false;

    let comp = existing[name];
    if (comp) {
        for (const c of [...comp.children]) c.remove();
        rebuilt.push(name);
    } else {
        comp = figma.createComponent();
        comp.name = `SF Symbol Name=${name}`;
        set.appendChild(comp);
        added.push(name);
    }
    comp.fills = [];
    comp.clipsContent = false;
    comp.resizeWithoutConstraints(width, height); // SwiftUI's layout box: no shared bounding box
    comp.appendChild(frame);
    frame.x = 0;
    frame.y = 0;
    frame.constraints = { horizontal: "SCALE", vertical: "SCALE" };
}

// Alphabetical grid, 8 per row on a 40pt pitch.
const sorted = [...set.children].sort((a, b) => a.name.localeCompare(b.name));
sorted.forEach((c, i) => { set.appendChild(c); c.x = 20 + (i % 8) * 40; c.y = 20 + Math.floor(i / 8) * 40; });
set.resizeWithoutConstraints(
    Math.max(...set.children.map((c) => c.x + c.width)) + 20,
    Math.max(...set.children.map((c) => c.y + c.height)) + 20);

// A resized instance keeps its size when its variant changes shape, which distorts the glyph.
// Keep its height (the point size it was scaled to) and restore the variant's proportions.
const reproportioned = [];
for (const c of set.children) {
    for (const inst of await c.getInstancesAsync()) {
        const width = c.width * (inst.height / c.height);
        if (Math.abs(inst.width - width) > 0.01) { inst.resize(width, inst.height); reproportioned.push(inst.id); }
    }
}

return { rebuilt, added, variants: set.children.length, reproportionedInstances: reproportioned };

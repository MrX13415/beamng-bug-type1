<!--
  One page of the owner's manual (used by BugManual.vue for the open pages and both faces of a turning leaf).

  page.kind:
    "cover"   front cover
    "toc"     contents (page.entries: chapters with their first page number; a click jumps there)
    "content" chapter page (page.blocks, page.first = chapter opener)
    "notes"   ruled notes page that fills the last spread

  Text formatting in the content JSON: **bold**, [Key] for a key cap.
-->
<template>
  <div class="mp" :class="[`mp-${page.kind}`, side === 'left' ? 'mp-l' : 'mp-r']">
    <!-- cover -->
    <template v-if="page.kind === 'cover'">
      <div class="mp-cover-photo" :style="{ backgroundImage: `url('${coverImage}')` }"></div>
      <div class="mp-cover-brand">{{ content.cover.brand }}</div>
      <div class="mp-cover-model">{{ content.cover.model }}</div>
    </template>

    <!-- contents -->
    <template v-else-if="page.kind === 'toc'">
      <div class="mp-body">
        <h2 class="mp-toc-title">{{ content.ui.contents }}</h2>
        <div class="mp-double-rule"></div>
        <ol class="mp-toc-list">
          <li v-for="entry in page.entries" :key="entry.id">
            <button class="mp-toc-entry" @click.stop="emit('jump', entry.page)">
              <span class="mp-toc-num">{{ entry.number || "" }}</span>
              <span class="mp-toc-name">{{ entry.title }}</span>
              <span class="mp-toc-dots"></span>
              <span class="mp-toc-page">{{ entry.page }}</span>
            </button>
          </li>
        </ol>
      </div>
      <div class="mp-folio">{{ page.number }}</div>
    </template>

    <!-- notes -->
    <template v-else-if="page.kind === 'notes'">
      <div class="mp-body">
        <h2 class="mp-notes-title">{{ content.ui.notes }}</h2>
        <div class="mp-notes-lines"></div>
      </div>
      <div class="mp-folio">{{ page.number }}</div>
    </template>

    <!-- chapter page -->
    <template v-else>
      <div v-if="!page.first" class="mp-running">{{ page.chapterTitle }}</div>
      <div class="mp-body">
        <header v-if="page.first" class="mp-opener">
          <div v-if="page.chapterNumber" class="mp-opener-label">{{ content.ui.chapter }} {{ page.chapterNumber }}</div>
          <h2 class="mp-opener-title">{{ page.chapterTitle }}</h2>
          <div class="mp-double-rule"></div>
        </header>

        <template v-for="(block, bi) in page.blocks" :key="bi">
          <h3 v-if="block.h" class="mp-h">
            <template v-for="(seg, si) in format(block.h)" :key="si"><span v-if="seg.kbd" class="mp-key" :class="{ b: seg.bold }">{{ seg.v }}</span><strong v-else-if="seg.bold">{{ seg.v }}</strong><template v-else>{{ seg.v }}</template></template>
          </h3>

          <p v-else-if="block.p" class="mp-p">
            <template v-for="(seg, si) in format(block.p)" :key="si"><span v-if="seg.kbd" class="mp-key" :class="{ b: seg.bold }">{{ seg.v }}</span><strong v-else-if="seg.bold">{{ seg.v }}</strong><template v-else>{{ seg.v }}</template></template>
          </p>

          <ol v-else-if="block.steps" class="mp-steps">
            <li v-for="(item, ii) in block.steps" :key="ii">
              <span class="mp-step-num">{{ ii + 1 }}</span>
              <span class="mp-step-text"><template v-for="(seg, si) in format(item)" :key="si"><span v-if="seg.kbd" class="mp-key" :class="{ b: seg.bold }">{{ seg.v }}</span><strong v-else-if="seg.bold">{{ seg.v }}</strong><template v-else>{{ seg.v }}</template></template></span>
            </li>
          </ol>

          <ul v-else-if="block.list" class="mp-list">
            <li v-for="(item, ii) in block.list" :key="ii">
              <template v-for="(seg, si) in format(item)" :key="si"><span v-if="seg.kbd" class="mp-key" :class="{ b: seg.bold }">{{ seg.v }}</span><strong v-else-if="seg.bold">{{ seg.v }}</strong><template v-else>{{ seg.v }}</template></template>
            </li>
          </ul>

          <aside v-else-if="block.note" class="mp-note">
            <span class="mp-note-label">{{ content.ui.note }}</span>
            <template v-for="(seg, si) in format(block.note)" :key="si"><span v-if="seg.kbd" class="mp-key" :class="{ b: seg.bold }">{{ seg.v }}</span><strong v-else-if="seg.bold">{{ seg.v }}</strong><template v-else>{{ seg.v }}</template></template>
          </aside>

          <table v-else-if="block.table" class="mp-table">
            <tbody>
              <tr v-for="(row, ri) in block.table" :key="ri">
                <th><template v-for="(seg, si) in format(row[0])" :key="si"><span v-if="seg.kbd" class="mp-key">{{ seg.v }}</span><template v-else>{{ seg.v }}</template></template></th>
                <td><template v-for="(seg, si) in format(row[1])" :key="si"><span v-if="seg.kbd" class="mp-key" :class="{ b: seg.bold }">{{ seg.v }}</span><strong v-else-if="seg.bold">{{ seg.v }}</strong><template v-else>{{ seg.v }}</template></template></td>
              </tr>
            </tbody>
          </table>
        </template>
      </div>
      <div class="mp-folio">{{ page.number }}</div>
    </template>
  </div>
</template>

<script setup>
const props = defineProps({
  page: { type: Object, required: true },
  content: { type: Object, required: true },
  side: { type: String, default: "right" },
})

const emit = defineEmits(["jump"])

// the mod's own render of the 1200 (blue-grey, no extras); the AW build has its own copy of this file
const coverImage = "/vehicles/bug/bug_1200_us_hardtop.jpg"

// "**bold** text with [Key]" -> [{ v, bold, kbd }]
function format(text) {
  const out = []
  String(text || "").split("**").forEach((part, i) => {
    const bold = i % 2 === 1
    part.split(/(\[[^\]]+\])/).forEach(piece => {
      if (!piece) return
      const kbd = piece.length > 2 && piece[0] === "[" && piece[piece.length - 1] === "]"
      out.push({ v: kbd ? piece.slice(1, -1) : piece, bold, kbd })
    })
  })
  return out
}
</script>

<style lang="scss" scoped>
// All sizes follow the page height (--ph, set by BugManual.vue), so a page holds the same text at any resolution.
.mp {
  --ink: #2a2318;
  --ink-soft: #5b4f3c;
  --accent: #8e2b1d;
  --rule: rgba(42, 35, 24, 0.55);

  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  color: var(--ink);
  font-family: "Georgia", "Times New Roman", serif;
  font-size: calc(var(--ph) * 0.0228);
  line-height: 1.42;
  text-align: left;
  user-select: none;
}

// paper margins: wider on the spine side
.mp-l { padding: 11.5% 11% 7.5% 9%; }
.mp-r { padding: 11.5% 9% 7.5% 11%; }

.mp-body {
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden;
}

.mp-running {
  position: absolute;
  top: 4.6%;
  left: 9%;
  right: 9%;
  padding-bottom: 0.3em;
  border-bottom: 1px solid var(--rule);
  font-size: 0.72em;
  letter-spacing: 0.16em;
  text-transform: uppercase;
  color: var(--ink-soft);
}
.mp-r .mp-running { text-align: right; }

.mp-folio {
  position: absolute;
  bottom: 3.6%;
  left: 0;
  right: 0;
  text-align: center;
  font-size: 0.8em;
  letter-spacing: 0.1em;
  color: var(--ink-soft);
  &::before { content: "— "; }
  &::after { content: " —"; }
}

.mp-double-rule {
  height: 0.28em;
  margin: 0.35em 0 1em;
  border-top: 2px solid var(--ink);
  border-bottom: 1px solid var(--ink);
}

// chapter opener
.mp-opener { margin-bottom: 0.4em; }
.mp-opener-label {
  font-size: 0.78em;
  letter-spacing: 0.22em;
  text-transform: uppercase;
  color: var(--accent);
}
.mp-opener-title {
  margin: 0.1em 0 0;
  font-family: "Palatino Linotype", "Book Antiqua", "Georgia", serif;
  font-size: 2em;
  font-weight: normal;
  line-height: 1.1;
}

.mp-h {
  margin: 0.9em 0 0.25em;
  font-size: 1em;
  font-weight: bold;
  letter-spacing: 0.04em;
  font-variant: small-caps;
  &:first-child { margin-top: 0; }
}

.mp-p { margin: 0 0 0.6em; text-align: justify; hyphens: auto; }

.mp-steps, .mp-list {
  margin: 0 0 0.6em;
  padding: 0;
  list-style: none;
  > li { margin: 0 0 0.35em; }
}
.mp-steps > li {
  display: flex;
  gap: 0.6em;
  align-items: baseline;
}
.mp-step-num {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 1.35em;
  height: 1.35em;
  border: 1.5px solid var(--accent);
  border-radius: 50%;
  font-size: 0.8em;
  font-weight: bold;
  color: var(--accent);
  transform: translateY(-0.1em);
}
.mp-step-text { flex: 1 1 auto; text-align: justify; hyphens: auto; }
.mp-list > li {
  position: relative;
  padding-left: 1.1em;
  text-align: justify;
  hyphens: auto;
  &::before {
    content: "";
    position: absolute;
    left: 0.15em;
    top: 0.7em;
    width: 0.5em;
    border-top: 1.5px solid var(--accent);
  }
}

.mp-note {
  margin: 0.8em 0 0.6em;
  padding: 0.5em 0.7em;
  border: 1px solid var(--rule);
  border-left: 4px solid var(--accent);
  background: rgba(142, 43, 29, 0.06);
  font-size: 0.92em;
}
.mp-note-label {
  margin-right: 0.5em;
  font-weight: bold;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  font-size: 0.85em;
  color: var(--accent);
}

.mp-table {
  width: 100%;
  margin: 0.3em 0 0.6em;
  border-collapse: collapse;
  th, td {
    padding: 0.42em 0;
    vertical-align: top;
    border-bottom: 1px dotted var(--rule);
  }
  th {
    width: 34%;
    padding-right: 0.8em;
    text-align: left;
    font-weight: bold;
    font-variant: small-caps;
    letter-spacing: 0.03em;
  }
  td { text-align: justify; hyphens: auto; }
  tr:first-child > * { border-top: 1px solid var(--rule); }
}

// key cap. Not a <kbd>: the game's global stylesheet styles kbd (white text), so all colours are set here.
.mp-key {
  display: inline-block;
  min-width: 1.1em;
  padding: 0 0.32em;
  border: 1px solid var(--ink-soft);
  border-bottom-width: 2px;
  border-radius: 0.2em;
  background: #fbf6e8;
  color: var(--ink);
  font-family: "Georgia", serif;
  font-size: 0.82em;
  font-weight: normal;
  line-height: 1.3;
  text-align: center;
  font-variant: normal;
  letter-spacing: normal;
  text-transform: none;
  text-shadow: none;
  &.b { font-weight: bold; }
}

// contents
.mp-toc-title, .mp-notes-title {
  margin: 0;
  font-family: "Palatino Linotype", "Book Antiqua", "Georgia", serif;
  font-size: 2em;
  font-weight: normal;
}
.mp-toc-list {
  margin: 0;
  padding: 0;
  list-style: none;
}
.mp-toc-entry {
  display: flex;
  align-items: baseline;
  width: 100%;
  margin: 0;
  padding: 0.45em 0.2em;
  border: none;
  border-radius: 0.2em;
  background: none;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
  &:hover, &:focus-visible {
    background: rgba(142, 43, 29, 0.08);
    outline: none;
    .mp-toc-name { color: var(--accent); }
  }
}
.mp-toc-num {
  flex: 0 0 1.6em;
  color: var(--accent);
  font-weight: bold;
}
.mp-toc-name { flex: 0 1 auto; }
.mp-toc-dots {
  flex: 1 1 auto;
  margin: 0 0.4em;
  border-bottom: 2px dotted var(--rule);
  transform: translateY(-0.25em);
}
.mp-toc-page { flex: 0 0 auto; }

// notes
.mp-notes-lines {
  height: 85%;
  margin-top: 1em;
  background: repeating-linear-gradient(to bottom, transparent 0, transparent calc(1.9em - 1px), var(--rule) calc(1.9em - 1px), var(--rule) 1.9em);
  opacity: 0.6;
}

// cover: aged off-white board, bold black lettering top right, black-and-white photo of the car's front
// bleeding off the left and bottom edges (the mod's own render, vehicles/bug/bug_1200_us_hardtop.jpg)
@font-face {
  font-family: "BugManualJost";
  src: url("/ui/ui-vue/mods/bug_manual/fonts/jost-800.woff2") format("woff2");
  font-weight: 800;
  font-display: block;
}
.mp-cover {
  padding: 0;
  color: #1c1a17;
}
.mp-cover-brand, .mp-cover-model {
  position: absolute;
  right: 6.5%;
  font-family: "BugManualJost", "Futura", "Century Gothic", "Arial Black", sans-serif;
  font-weight: 800;
  font-size: 3.55em;
  line-height: 1;
  letter-spacing: -0.01em;
  text-transform: uppercase;
  white-space: nowrap;
}
.mp-cover-brand { top: 3.2%; left: 6%; text-align: left; }
.mp-cover-model { top: 9.6%; text-align: right; }
.mp-cover-photo {
  position: absolute;
  left: 0;
  top: 17%;
  width: 80%;
  bottom: 0;
  background-repeat: no-repeat;
  // close-up of the near front fender and headlamp: source area about x 587..830, y 60..420 of the 1000 x 562 render
  background-size: auto 156%;
  background-position: 77.5% 30%;
  // black and white; brightened so the grey studio background turns to paper colour under multiply
  filter: grayscale(1) brightness(1.22) contrast(1.6);
  mix-blend-mode: multiply;
  // soft top and right edges instead of a hard photo rectangle
  -webkit-mask-image: linear-gradient(to right, #000 86%, transparent 100%), linear-gradient(to bottom, transparent 0%, #000 16%);
  -webkit-mask-composite: source-in;
  mask-image: linear-gradient(to right, #000 86%, transparent 100%), linear-gradient(to bottom, transparent 0%, #000 16%);
  mask-composite: intersect;
}
</style>

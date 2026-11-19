<!--
  Owner's manual of the Bug: a book on the screen, opened by clicking the manual in the open glovebox.
  Route "bug.manual" (index.js); game side: lua/ge/extensions/bug/manual.lua (extension bug_manual).

  - Text: content/<language>.json (English and German; other languages use English). The texts are JSON so
    the AW build (Tools/py/buildaw.py) rebrands them like the other text files.
  - Spread 0 is the closed book (cover only). Spread n >= 1 shows pages 2n-1 (left) and 2n (right).
  - Pages turn with a 3D leaf: arrow keys / PageUp / PageDown, gamepad tab and left / right, the arrow
    buttons beside the book, or a click on a lower page corner. The contents page jumps to a chapter.
  - Esc / gamepad back / the close button: bug_manual.close() goes back to the game.
  - The open spread is kept in the extension, so the book reopens where it was left.
-->
<template>
  <div
    class="bm"
    :style="sizeVars"
    v-bng-on-ui-nav:back,menu="close"
    v-bng-on-ui-nav:tab_l,focus_l="prev"
    v-bng-on-ui-nav:tab_r,focus_r="next"
  >
    <div class="bm-backdrop" @click="close"></div>

    <button class="bm-close" :title="content.ui.close" @click="close">
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6 L18 18 M18 6 L6 18" /></svg>
      <span>{{ content.ui.close }}</span>
    </button>

    <div class="bm-stage">
      <button class="bm-arrow bm-arrow-l" :disabled="!canPrev" :title="content.ui.prev" @click="prev">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 4 L7 12 L15 20" /></svg>
      </button>

      <div class="bm-book" :class="{ 'bm-closed': shownClosed }">
        <!-- left page -->
        <div v-if="under.left" class="bm-page bm-page-l" :class="paperClass(under.left)">
          <ManualPage :page="under.left" :content="content" side="left" @jump="jumpToPage" />
          <div v-if="!turning && canPrev" class="bm-corner bm-corner-l" :title="content.ui.prev" @click.stop="prev"></div>
        </div>
        <!-- right page -->
        <div v-if="under.right" class="bm-page bm-page-r" :class="paperClass(under.right)">
          <ManualPage :page="under.right" :content="content" side="right" @jump="jumpToPage" />
          <div v-if="!turning && canNext" class="bm-corner bm-corner-r" :title="content.ui.next" @click.stop="next"></div>
        </div>

        <!-- turning leaf -->
        <div v-if="turning" ref="leafEl" class="bm-leaf" :class="turning.dir > 0 ? 'bm-leaf-fwd' : 'bm-leaf-back'">
          <div class="bm-leaf-face bm-leaf-front bm-page" :class="[paperClass(turning.front), turning.dir > 0 ? 'bm-page-r' : 'bm-page-l']">
            <ManualPage v-if="turning.front" :page="turning.front" :content="content" :side="turning.dir > 0 ? 'right' : 'left'" />
          </div>
          <div class="bm-leaf-face bm-leaf-back-face bm-page" :class="[paperClass(turning.back), turning.dir > 0 ? 'bm-page-l' : 'bm-page-r']">
            <ManualPage v-if="turning.back" :page="turning.back" :content="content" :side="turning.dir > 0 ? 'left' : 'right'" />
          </div>
        </div>
      </div>

      <button class="bm-arrow bm-arrow-r" :disabled="!canNext" :title="content.ui.next" @click="next">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 4 L17 12 L9 20" /></svg>
      </button>
    </div>

    <div class="bm-hint">{{ content.ui.hint }}</div>
  </div>
</template>

<script setup>
import { ref, computed, nextTick, onMounted, onBeforeUnmount } from "vue"
import { useBridge } from "@/bridge"
import { vBngOnUiNav } from "@/common/directives"
import ManualPage from "./ManualPage.vue"
import contentEn from "./content/en-US.json"
import contentDe from "./content/de-DE.json"

const PAGE_RATIO = 0.7     // page width / height
const TURN_MS = 650        // page turn duration
const { api } = useBridge()

// statements run without a callback; with a callback the bridge sends the code as an argument, so it must be an expression
const luaRun = code => api.engineLua(code)
const luaGet = expr => new Promise(resolve => api.engineLua(expr, resolve))

// ---- language ---------------------------------------------------------------------------------
function currentLocale() {
  try {
    const loc = window.vueI18n?.global?.locale
    const value = loc && typeof loc === "object" ? loc.value : loc
    if (value) return String(value)
  } catch (e) { /* fall through */ }
  return navigator.language || "en-US"
}
const content = currentLocale().toLowerCase().startsWith("de") ? contentDe : contentEn

// ---- pages ------------------------------------------------------------------------------------
const personality = ref(false)   // Herbie chapter, set from the extension state

const pages = computed(() => {
  const chapters = content.chapters.filter(ch => !ch.requires || (ch.requires === "personality" && personality.value))
  const list = [{ kind: "cover" }]
  const toc = { kind: "toc", entries: [] }

  // page 1: first chapter (foreword), page 2: contents, then the other chapters
  let number = 0
  chapters.forEach((ch, ci) => {
    const chapterNumber = ci === 0 ? 0 : ci  // the foreword has no number
    ch.pages.forEach((blocks, pi) => {
      if (list.length === 2) list.push(toc)
      const pageNumber = list.length
      if (pi === 0) toc.entries.push({ id: ch.id, number: chapterNumber, title: ch.title, page: pageNumber })
      list.push({ kind: "content", blocks, first: pi === 0, chapterTitle: ch.title, chapterNumber, number: pageNumber })
    })
  })
  if (list.length === 2) list.push(toc)
  toc.number = list.indexOf(toc)
  // fill the last spread with a notes page
  if ((list.length - 1) % 2 === 1) list.push({ kind: "notes", number: list.length })
  return list
})

const spreadCount = computed(() => 1 + Math.ceil((pages.value.length - 1) / 2))
const spreadPages = s => s <= 0
  ? { left: null, right: pages.value[0] }
  : { left: pages.value[2 * s - 1] || null, right: pages.value[2 * s] || null }

// ---- state ------------------------------------------------------------------------------------
const spread = ref(0)
const turning = ref(null)  // { dir, from, to, front, back }
const leafEl = ref(null)
let closing = false

const under = computed(() => {
  if (!turning.value) return spreadPages(spread.value)
  const { dir, from, to } = turning.value
  return dir > 0
    ? { left: spreadPages(from).left, right: spreadPages(to).right }
    : { left: spreadPages(to).left, right: spreadPages(from).right }
})
// the book slides to the side while closed, so the cover is centred
const shownClosed = computed(() => turning.value ? turning.value.to === 0 : spread.value === 0)
const canPrev = computed(() => spread.value > 0)
const canNext = computed(() => spread.value < spreadCount.value - 1)

function paperClass(page) {
  return page && page.kind === "cover" ? "bm-cover" : "bm-paper"
}

async function turnTo(target) {
  target = Math.max(0, Math.min(spreadCount.value - 1, target))
  if (turning.value || target === spread.value) return
  const from = spread.value
  const dir = target > from ? 1 : -1
  turning.value = {
    dir, from, to: target,
    front: dir > 0 ? spreadPages(from).right : spreadPages(from).left,
    back: dir > 0 ? spreadPages(target).left : spreadPages(target).right,
  }
  await nextTick()
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
  const el = leafEl.value
  if (el && el.animate) {
    const anim = el.animate(
      [{ transform: "rotateY(0deg)" }, { transform: `rotateY(${dir > 0 ? -180 : 180}deg)` }],
      { duration: TURN_MS, easing: "cubic-bezier(0.45, 0.05, 0.35, 1)", fill: "forwards" },
    )
    // the timer makes sure a turn always ends, even if the animation never reports it finished
    const timeout = new Promise(resolve => setTimeout(resolve, TURN_MS + 150))
    try { await Promise.race([anim.finished, timeout]) } catch (e) { /* cancelled */ }
  }
  spread.value = target
  turning.value = null
  luaRun(`if extensions.bug_manual then extensions.bug_manual.setPage(${target}) end`)
}

const next = () => turnTo(spread.value + 1)
const prev = () => turnTo(spread.value - 1)
const jumpToPage = page => turnTo(Math.floor(page / 2) + (page % 2))  // page 2n-1 / 2n -> spread n

function close() {
  if (closing) return
  closing = true
  luaRun("if extensions.bug_manual then extensions.bug_manual.close() else ui_router.navigate('play') end")
  setTimeout(() => { closing = false }, 1000)
}

// ---- size: everything scales with the page height ---------------------------------------------
const viewport = ref({ w: window.innerWidth, h: window.innerHeight })
const sizeVars = computed(() => {
  const ph = Math.min(viewport.value.h * 0.82, (viewport.value.w * 0.84) / (2 * PAGE_RATIO))
  return { "--ph": `${ph}px`, "--pw": `${ph * PAGE_RATIO}px`, "--turn": `${TURN_MS}ms` }
})
const onResize = () => { viewport.value = { w: window.innerWidth, h: window.innerHeight } }

// keyboard fallback (the UI nav events above normally cover these; a turn in progress ignores repeats)
function onKey(e) {
  if (e.repeat) return
  switch (e.key) {
    case "ArrowRight": case "PageDown": next(); break
    case "ArrowLeft": case "PageUp": prev(); break
    case "Home": turnTo(0); break
    case "End": turnTo(spreadCount.value - 1); break
    case "Escape": close(); break
    default: return
  }
  e.preventDefault()
}

onMounted(async () => {
  window.addEventListener("resize", onResize)
  window.addEventListener("keydown", onKey)
  const state = await luaGet("extensions.bug_manual and extensions.bug_manual.getState() or {}")
  if (state && typeof state === "object") {
    personality.value = state.personality === true
    const page = Number(state.page) || 0
    if (page > 0) spread.value = Math.min(page, spreadCount.value - 1)
  }
})

onBeforeUnmount(() => {
  window.removeEventListener("resize", onResize)
  window.removeEventListener("keydown", onKey)
})
</script>

<style lang="scss" scoped>
.bm {
  position: absolute;
  inset: 0;
  z-index: 10;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  pointer-events: auto;
  animation: bm-fade 0.35s ease-out;
}

.bm-backdrop {
  position: absolute;
  inset: 0;
  background: radial-gradient(ellipse at center, rgba(20, 16, 10, 0.35) 0%, rgba(8, 6, 4, 0.75) 100%);
}

.bm-stage {
  position: relative;
  display: flex;
  align-items: center;
  gap: calc(var(--ph) * 0.035);
  animation: bm-rise 0.45s cubic-bezier(0.2, 0.8, 0.2, 1);
}

// ---- book ----
.bm-book {
  position: relative;
  width: calc(var(--pw) * 2);
  height: var(--ph);
  perspective: calc(var(--ph) * 3.2);
  transform: translateX(0);
  transition: transform var(--turn) cubic-bezier(0.45, 0.05, 0.35, 1);
  &.bm-closed { transform: translateX(calc(var(--pw) * -0.5)); }
}

.bm-page {
  contain: layout paint style;
  position: absolute;
  top: 0;
  width: var(--pw);
  height: var(--ph);
}
.bm-page-l {
  left: 0;
  border-radius: 0.5% 0 0 0.5% / 0.35% 0 0 0.35%;
}
.bm-page-r {
  left: var(--pw);
  border-radius: 0 0.5% 0.5% 0 / 0 0.35% 0.35% 0;
}

// paper: warm off-white, faint grain, darker towards the spine, a stack of page edges outside
.bm-paper {
  background-color: #f1e7cd;
  background-image: radial-gradient(ellipse at 50% 40%, rgba(255, 252, 240, 0.6) 0%, rgba(214, 196, 156, 0.35) 100%);
}
.bm-page-l.bm-paper {
  box-shadow:
    inset calc(var(--pw) * -0.09) 0 calc(var(--pw) * 0.07) calc(var(--pw) * -0.06) rgba(60, 40, 15, 0.45),
    -1px 1px 0 #e3d8bb, -2px 2px 0 #cdbf9c, -3px 3px 0 #e3d8bb, -4px 4px 0 #c6b892, -5px 5px 0 #ddd1b2,
    0 calc(var(--ph) * 0.03) calc(var(--ph) * 0.06) rgba(0, 0, 0, 0.55);
}
.bm-page-r.bm-paper {
  box-shadow:
    inset calc(var(--pw) * 0.09) 0 calc(var(--pw) * 0.07) calc(var(--pw) * -0.06) rgba(60, 40, 15, 0.45),
    1px 1px 0 #e3d8bb, 2px 2px 0 #cdbf9c, 3px 3px 0 #e3d8bb, 4px 4px 0 #c6b892, 5px 5px 0 #ddd1b2,
    0 calc(var(--ph) * 0.03) calc(var(--ph) * 0.06) rgba(0, 0, 0, 0.55);
}

// cover: aged off-white board with a few stains and darker, worn edges (period "Volkswagen 1200" manual)
.bm-cover {
  background-color: #e6dcc3;
  background-image:
    radial-gradient(circle at 78% 64%, rgba(150, 120, 70, 0.10) 0, rgba(150, 120, 70, 0) 9%),
    radial-gradient(circle at 88% 30%, rgba(150, 120, 70, 0.08) 0, rgba(150, 120, 70, 0) 6%),
    radial-gradient(circle at 20% 12%, rgba(150, 120, 70, 0.07) 0, rgba(150, 120, 70, 0) 7%),
    radial-gradient(ellipse at 50% 45%, rgba(255, 250, 235, 0.55) 0%, rgba(255, 250, 235, 0) 60%),
    linear-gradient(to bottom, rgba(120, 95, 55, 0.12), rgba(120, 95, 55, 0) 12%, rgba(120, 95, 55, 0) 88%, rgba(120, 95, 55, 0.16));
  box-shadow:
    inset 0 0 calc(var(--pw) * 0.05) rgba(110, 85, 45, 0.35),
    1px 1px 0 #d8ccad, 2px 2px 0 #c2b48f, 3px 3px 0 #d8ccad,
    0 calc(var(--ph) * 0.03) calc(var(--ph) * 0.06) rgba(0, 0, 0, 0.55);
  overflow: hidden;
  &.bm-page-r { border-radius: 0 0.8% 0.8% 0 / 0 0.55% 0.55% 0; }
  &.bm-page-l { border-radius: 0.8% 0 0 0.8% / 0.55% 0 0 0.55%; }
}

// lower outer corner: click to turn, shows a small curl on hover
.bm-corner {
  position: absolute;
  bottom: 0;
  width: 14%;
  height: 10%;
  cursor: pointer;
  z-index: 2;
  &::after {
    content: "";
    position: absolute;
    bottom: 0;
    width: 0;
    height: 0;
    opacity: 0;
    transition: width 0.18s ease, height 0.18s ease, opacity 0.18s ease;
  }
  &:hover::after { width: 46%; height: 64%; opacity: 1; }
}
.bm-corner-r {
  right: 0;
  &::after {
    right: 0;
    background: linear-gradient(315deg, rgba(0, 0, 0, 0) 50%, #e2d6b6 50%, #f6eed8 70%, #cbbd99 100%);
    box-shadow: -2px -2px 5px rgba(0, 0, 0, 0.2);
  }
}
.bm-corner-l {
  left: 0;
  &::after {
    left: 0;
    background: linear-gradient(45deg, rgba(0, 0, 0, 0) 50%, #e2d6b6 50%, #f6eed8 70%, #cbbd99 100%);
    box-shadow: 2px -2px 5px rgba(0, 0, 0, 0.2);
  }
}

// ---- turning leaf ----
.bm-leaf {
  position: absolute;
  top: 0;
  width: var(--pw);
  height: var(--ph);
  transform-style: preserve-3d;
  will-change: transform;
  z-index: 5;
}
.bm-leaf-face.bm-page { box-shadow: none; }
.bm-leaf-fwd { left: var(--pw); transform-origin: 0 50%; }
.bm-leaf-back { left: 0; transform-origin: 100% 50%; }

.bm-leaf-face {
  position: absolute;
  top: 0;
  left: 0;
  backface-visibility: hidden;
  -webkit-backface-visibility: hidden;
  overflow: hidden;
  &::after {
    content: "";
    position: absolute;
    inset: 0;
    pointer-events: none;
    animation: bm-shade var(--turn) ease-in-out forwards;
  }
}
.bm-leaf-back-face { transform: rotateY(180deg); }
.bm-leaf-fwd .bm-leaf-front::after { background: linear-gradient(to left, rgba(0, 0, 0, 0.35), rgba(0, 0, 0, 0) 60%); }
.bm-leaf-fwd .bm-leaf-back-face::after { background: linear-gradient(to right, rgba(0, 0, 0, 0.35), rgba(0, 0, 0, 0) 60%); }
.bm-leaf-back .bm-leaf-front::after { background: linear-gradient(to right, rgba(0, 0, 0, 0.35), rgba(0, 0, 0, 0) 60%); }
.bm-leaf-back .bm-leaf-back-face::after { background: linear-gradient(to left, rgba(0, 0, 0, 0.35), rgba(0, 0, 0, 0) 60%); }

// ---- controls ----
.bm-arrow {
  display: flex;
  align-items: center;
  justify-content: center;
  width: calc(var(--ph) * 0.07);
  height: calc(var(--ph) * 0.07);
  padding: 0;
  border: 1px solid rgba(241, 231, 205, 0.35);
  border-radius: 50%;
  background: rgba(20, 16, 10, 0.45);
  color: #f1e7cd;
  cursor: pointer;
  transition: background 0.15s, opacity 0.15s, transform 0.15s;
  svg {
    width: 50%;
    height: 50%;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.2;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
  &:hover:not(:disabled) { background: rgba(142, 43, 29, 0.75); transform: scale(1.06); }
  &:disabled { opacity: 0.2; cursor: default; }
}

.bm-close {
  position: absolute;
  top: calc(var(--ph) * 0.035);
  right: calc(var(--ph) * 0.045);
  z-index: 3;
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.45em 0.95em 0.45em 0.7em;
  border: 1px solid rgba(241, 231, 205, 0.35);
  border-radius: 2em;
  background: rgba(20, 16, 10, 0.5);
  color: #f1e7cd;
  font-family: "Georgia", serif;
  font-size: calc(var(--ph) * 0.02);
  letter-spacing: 0.06em;
  cursor: pointer;
  transition: background 0.15s;
  svg {
    width: 1.1em;
    height: 1.1em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.4;
    stroke-linecap: round;
  }
  &:hover { background: rgba(142, 43, 29, 0.75); }
}

.bm-hint {
  position: relative;
  margin-top: calc(var(--ph) * 0.035);
  color: rgba(241, 231, 205, 0.7);
  font-family: "Georgia", serif;
  font-size: calc(var(--ph) * 0.017);
  letter-spacing: 0.04em;
  text-align: center;
}

@keyframes bm-fade { from { opacity: 0; } to { opacity: 1; } }
@keyframes bm-rise { from { opacity: 0; transform: translateY(2%) scale(0.97); } to { opacity: 1; transform: none; } }
@keyframes bm-shade { 0% { opacity: 0; } 50% { opacity: 1; } 100% { opacity: 0; } }
</style>

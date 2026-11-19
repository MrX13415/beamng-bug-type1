<template>
  <!-- the whole page lets the mouse through to the game; only the bar at the bottom takes it -->
  <div class="wt">
    <div class="wt-bar" @mouseenter="setOverBar(true)" @mouseleave="setOverBar(false)">
      <div class="wt-tools">
        <button
          v-for="t in tools"
          :key="t.id"
          class="wt-tool"
          :class="{ selected: state.tool === t.id }"
          :title="text.tools[t.id]"
          @click="selectTool(t.id)"
        >
          <svg viewBox="0 0 24 24" class="wt-icon" aria-hidden="true">
            <path :d="t.icon" />
          </svg>
        </button>
      </div>

      <div class="wt-hint">
        <template v-if="state.hover">
          <span class="wt-name">{{ text.hotspots[state.hover.label] || state.hover.label }}</span>
          <span v-if="state.hover.value" class="wt-value">{{ formatValue(state.hover.value) }}</span>
          <span class="wt-how">{{ state.hover.noUse ? text.noUse : !state.hover.usable ? text.wrongTool : state.hover.drag ? (state.hover.dragging ? text.dragging : text.drag) : text.scroll }}</span>
        </template>
        <template v-else>
          <span class="wt-how">{{ state.orbiting ? text.orbiting : text.point }}</span>
          <span class="wt-keys">
            <span class="wt-key">{{ text.rmb }}</span>{{ text.look }}
            <span class="wt-key">+ {{ text.wheel }}</span>{{ text.zoom }}
            <span v-if="state.orbiting" class="wt-key">+ {{ text.mmb }}</span><template v-if="state.orbiting">{{ text.height }}</template>
          </span>
        </template>
      </div>

      <button class="wt-exit" @click="close">
        <span class="wt-key">Esc</span>{{ text.leave }}
      </button>
    </div>
  </div>
</template>

<script setup>
import { reactive, onMounted, onBeforeUnmount } from "vue"
import { useBridge } from "@/bridge"

const { api, events } = useBridge()

// ---- text (the AW build rewrites json/lua only, so no brand names here) -------------------------------------------
const TEXT = {
  en: {
    tools: { screwdriver: "Screwdriver" },
    hotspots: {
      idleScrew: "Idle screw",
      throttleLever: "Throttle lever",
      chokeCoverScrew: "Choke cover screw",
      chokeCover: "Automatic choke cover",
      springArm: "Return spring bracket",
      springArmScrew: "Spring bracket screw",
    },
    // hotspot values sent as {key, n} by the car (lib/workmode.lua)
    values: {
      screwTight: "tight",
      screwOut: "{n} turns out",
      coverDeg: "{n}° from the mark (+ = richer)",
      coverClamped: "clamped: loosen the three screws",
    },
    point: "Point at a part",
    orbiting: "Camera mode",
    rmb: "Right mouse",
    look: "camera",
    wheel: "Wheel",
    zoom: "zoom",
    mmb: "Middle mouse",
    height: "up / down",
    scroll: "Scroll to turn",
    drag: "Hold left mouse and drag to open",
    dragging: "Let go to release",
    wrongTool: "Needs another tool",
    noUse: "Can't be worked on yet",
    leave: "Leave",
  },
  de: {
    tools: { screwdriver: "Schraubendreher" },
    hotspots: {
      idleScrew: "Leerlaufschraube",
      throttleLever: "Gashebel",
      chokeCoverScrew: "Schraube des Startdeckels",
      chokeCover: "Deckel der Startautomatik",
      springArm: "Halter der Rückholfeder",
      springArmScrew: "Schraube des Federhalters",
    },
    values: {
      screwTight: "fest",
      screwOut: "{n} Umdrehungen gelöst",
      coverDeg: "{n}° von der Marke (+ = fetter)",
      coverClamped: "geklemmt: die drei Schrauben lösen",
    },
    point: "Mit der Maus auf ein Teil zeigen",
    orbiting: "Kameramodus",
    rmb: "Rechte Maustaste",
    look: "Kamera",
    wheel: "Mausrad",
    zoom: "zoomen",
    mmb: "Mittlere Maustaste",
    height: "hoch / runter",
    scroll: "Zum Drehen scrollen",
    drag: "Linke Maustaste halten und ziehen zum Öffnen",
    dragging: "Loslassen zum Freigeben",
    wrongTool: "Braucht ein anderes Werkzeug",
    noUse: "Noch nicht bearbeitbar",
    leave: "Beenden",
  },
}
function currentLocale() {
  try {
    const loc = window.vueI18n?.global?.locale
    const value = loc && typeof loc === "object" ? loc.value : loc
    if (value) return String(value)
  } catch (e) { /* fall through */ }
  return navigator.language || "en-US"
}
const text = currentLocale().toLowerCase().startsWith("de") ? TEXT.de : TEXT.en

// a hotspot's value: a string, or {key, n} for a text in text.values with n filled in
function formatValue(v) {
  if (!v || typeof v !== "object") return v
  return (text.values[v.key] || v.key).replace("{n}", v.n ?? "")
}

// proof of concept: one tool
const tools = [
  // flat-blade screwdriver, diagonal
  { id: "screwdriver", icon: "M14.6 3.3a1 1 0 0 1 1.4 0l4.7 4.7a1 1 0 0 1 0 1.4l-2.1 2.1-1.4-1.4-5.2 5.2.7.7-1.4 1.4-.7-.7-4.6 4.6a1.5 1.5 0 0 1-2.1-2.1l4.6-4.6-.7-.7 1.4-1.4.7.7 5.2-5.2-1.4-1.4z" },
]

// ---- state from the GE extension bug_worktop ----------------------------------------------------------------------
const state = reactive({ active: false, tool: "screwdriver", orbiting: false, hover: null })

function onState(data) {
  if (!data) return
  state.active = !!data.active
  state.tool = data.tool || "screwdriver"
  state.orbiting = !!data.orbiting
  state.hover = data.hover || null
}

const luaRun = code => api.engineLua(code)
function selectTool(id) { luaRun(`if bug_worktop then bug_worktop.selectTool(${JSON.stringify(id)}) end`) }
function close() { luaRun("if bug_worktop then bug_worktop.close() end") }
// the cursor is over the bar: the 3D view under it isn't pointed at (the game's own UI focus flag can stay set after
// the cursor has left, which switched the hover off)
function setOverBar(over) { luaRun(`if bug_worktop then bug_worktop.setOverBar(${over ? "true" : "false"}) end`) }

onMounted(() => events.on("BugWorktopState", onState))
onBeforeUnmount(() => {
  events.off("BugWorktopState", onState)
  setOverBar(false)
})
</script>

<style lang="scss" scoped>
.wt {
  position: fixed;
  inset: 0;
  pointer-events: none;   // the 3D view gets the mouse (cursor ray for the screws, mouse wheel)
  display: flex;
  align-items: flex-end;
  justify-content: center;
  padding-bottom: 3vh;
  font-family: var(--fnt-defs, sans-serif);
}
.wt-bar {
  pointer-events: auto;
  display: flex;
  align-items: center;
  gap: 1.2em;
  padding: 0.6em 0.8em;
  border-radius: 0.6em;
  background: rgba(20, 20, 22, 0.78);
  color: #eee;
  box-shadow: 0 0.3em 1.2em rgba(0, 0, 0, 0.45);
  font-size: 1rem;
}
.wt-tools { display: flex; gap: 0.4em; }
.wt-tool {
  width: 2.8em;
  height: 2.8em;
  border-radius: 0.45em;
  border: 2px solid rgba(255, 255, 255, 0.15);
  background: rgba(255, 255, 255, 0.06);
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  &.selected { border-color: rgb(230, 159, 0); background: rgba(230, 159, 0, 0.18); }
}
.wt-icon { width: 1.6em; height: 1.6em; fill: #eee; }
.wt-hint { display: flex; align-items: baseline; gap: 0.8em; min-width: 26em; }
.wt-name { font-weight: 700; }
.wt-value { font-variant-numeric: tabular-nums; color: rgb(230, 159, 0); font-weight: 700; }
.wt-how { opacity: 0.7; }
.wt-keys {
  display: flex;
  align-items: baseline;
  gap: 0.35em;
  opacity: 0.7;
  font-size: 0.85em;
  .wt-key:not(:first-child) { margin-left: 0.6em; }
}
.wt-exit {
  display: flex;
  align-items: center;
  gap: 0.5em;
  border: none;
  background: rgba(255, 255, 255, 0.08);
  color: #eee;
  padding: 0.4em 0.7em;
  border-radius: 0.4em;
  cursor: pointer;
  font-size: 0.9em;
}
.wt-key {
  font-size: 0.8em;
  font-weight: 700;
  padding: 0.1em 0.4em;
  border-radius: 0.25em;
  border: 1px solid rgba(255, 255, 255, 0.4);
}
</style>

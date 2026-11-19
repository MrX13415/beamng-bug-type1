// "Service" / "Wartung" tab, concept: shared data access for the cards of the pause-menu
// tab. The tab and its buttons are registered from Lua (lua/ge/extensions/bug/service.lua).
//
// The vehicle pushes a snapshot to bug_service once a second; the cards poll the last one. A paused
// simulation shows the last snapshot (the age is shown).

import { ref, onMounted, onBeforeUnmount } from "vue"
import { useBridge } from "@/bridge"

const POLL_MS = 1000

export function useServiceState() {
  const { api } = useBridge()
  const state = ref(null)
  let timer = null

  function poll() {
    // rawget: the extension is a global only after a Bug loaded it
    api.engineLua("rawget(_G, 'bug_service') and bug_service.getState() or false", data => {
      state.value = data || null
    })
  }

  onMounted(() => {
    poll()
    timer = setInterval(poll, POLL_MS)
  })
  onBeforeUnmount(() => clearInterval(timer))

  return { state, refresh: poll }
}

// raw jbeam values → one Lua call (the car respawns once)
export function setServiceSettings(values) {
  const { api } = useBridge()
  const entries = Object.entries(values).map(([k, v]) => `[${JSON.stringify(k)}]=${Number(v)}`)
  api.engineLua(`if rawget(_G, "bug_service") then bug_service.setSettings({${entries.join(",")}}) end`)
}

// ---- formatting ----
export const fmt = {
  num(v, digits = 0, unit = "") {
    if (v === null || v === undefined || Number.isNaN(Number(v))) return "–"
    return Number(v).toFixed(digits) + (unit ? " " + unit : "")
  },
  pct(v, digits = 0) {
    if (v === null || v === undefined) return "–"
    return (Number(v) * 100).toFixed(digits) + " %"
  },
  duration(sec) {
    if (sec === null || sec === undefined) return "–"
    sec = Math.max(0, Math.round(sec))
    const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60)
    if (d > 0) return `${d} d ${h} h`
    if (h > 0) return `${h} h ${m} min`
    return `${m} min ${sec % 60} s`
  },
  date(epochSec) {
    if (!epochSec) return "–"
    return new Date(epochSec * 1000).toLocaleString()
  },
  km(m) {
    if (m === null || m === undefined) return "–"
    return (Number(m) / 1000).toFixed(1) + " km"
  },
}

export const REALISM_LABELS = ["Off", "Forgiving", "Realistic", "Hardcore"]

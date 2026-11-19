<template>
  <div class="side">
    <h3>Service · concept</h3>
    <p>
      Everything about this one car: its condition, its service history and the settings of the simulation
      behind it. A concept: nothing here changes how the car drives yet.
    </p>
    <ul>
      <li><span class="tag real">real</span> read from the running car</li>
      <li><span class="tag preview">preview</span> computed, not applied</li>
      <li><span class="tag mock">mock</span> placeholder values</li>
    </ul>
    <div class="link">
      <template v-if="state">
        Vehicle {{ state.vehicleId }} · realism <b>{{ REALISM_LABELS[state.settings.realism] ?? state.settings.realism }}</b><br />
        Snapshot age: {{ age }}
      </template>
      <template v-else>No snapshot from a Bug yet.</template>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from "vue"
import { useServiceState, fmt, REALISM_LABELS } from "./useServiceState.js"

const { state } = useServiceState()
const now = ref(Date.now() / 1000)
let t = null
onMounted(() => { t = setInterval(() => { now.value = Date.now() / 1000 }, 1000) })
onBeforeUnmount(() => clearInterval(t))

// the snapshot's wall clock is the game's os.time(); a paused simulation stops sending
const age = computed(() => state.value ? fmt.duration(now.value - state.value.wallClock) : "–")
</script>

<style lang="scss" scoped>
.side { padding: 0.5em 0.25em; color: var(--bng-off-white, #eee); line-height: 1.4; }
h3 { margin: 0 0 0.5em; }
p { opacity: 0.8; margin: 0 0 0.8em; }
ul { list-style: none; padding: 0; margin: 0 0 1em; display: flex; flex-direction: column; gap: 0.3em; }
.tag {
  display: inline-block; min-width: 5.5em; text-align: center;
  font-size: 0.7em; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em;
  padding: 0.1em 0.5em; border-radius: 0.3em; margin-right: 0.4em;
  &.real { background: rgba(0, 158, 115, 0.35); }
  &.mock { background: rgba(230, 159, 0, 0.4); }
  &.preview { background: rgba(86, 180, 233, 0.35); }
}
.link { font-size: 0.85em; opacity: 0.7; }
</style>

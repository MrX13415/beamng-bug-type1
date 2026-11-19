<template>
  <div class="es">
    <p class="es-note">
      These are the same values as <b>Vehicle Configuration → Tuning → Service</b>. They are jbeam variables,
      so they are saved with the configuration (.pc). Applying them respawns the car, like any Tuning change.
      Nothing acts on them yet.
    </p>

    <div v-if="!state" class="es-note">No data yet. Sit in a Bug and let the simulation run for a second.</div>

    <template v-else>
      <section>
        <h3>Realism</h3>
        <div class="seg">
          <BngButton
            v-for="(label, i) in REALISM_LABELS"
            :key="label"
            :accent="draft.realism === i ? ACCENTS.main : ACCENTS.outlined"
            @click="draft.realism = i"
          >{{ label }}</BngButton>
        </div>
      </section>

      <section>
        <h3>Simulation</h3>
        <label>Fault rate</label>
        <BngSlider v-model="draft.faultRatePct" :min="0" :max="300" :step="10" unit="%" with-input />
        <label>Standing-time simulation</label>
        <BngSlider v-model="draft.parkedSimPct" :min="0" :max="100" :step="5" unit="%" with-input />
      </section>

      <section>
        <h3>Start state (car without a saved state)</h3>
        <label>Battery charge</label>
        <BngSlider v-model="draft.startBatteryPct" :min="0" :max="100" :step="5" unit="%" with-input />
        <label>Oil age</label>
        <BngSlider v-model="draft.startOilKm" :min="0" :max="5000" :step="100" unit="km" with-input />
      </section>

      <div class="actions">
        <BngButton :disabled="!changed" @click="apply">Apply (respawns the car)</BngButton>
        <BngButton :accent="ACCENTS.outlined" :disabled="!changed" @click="load">Undo</BngButton>
      </div>
    </template>
  </div>
</template>

<script setup>
import { reactive, computed, watch } from "vue"
import { BngButton, BngSlider, ACCENTS } from "@/common/components/base"
import { useServiceState, setServiceSettings, REALISM_LABELS } from "./useServiceState.js"

const { state } = useServiceState()
const draft = reactive({ realism: 2, faultRatePct: 100, parkedSimPct: 100, startBatteryPct: 100, startOilKm: 0 })
let loaded = null

function fromSettings(s) {
  return {
    realism: s.realism,
    faultRatePct: Math.round(s.faultRate * 100),
    parkedSimPct: Math.round(s.parkedSim * 100),
    startBatteryPct: Math.round(s.startBattery * 100),
    startOilKm: Math.round(s.startOilKm),
  }
}

function load() {
  if (!state.value?.settings) return
  loaded = fromSettings(state.value.settings)
  Object.assign(draft, loaded)
}

// take the values once, when the first snapshot arrives (later polls don't overwrite the draft)
watch(state, s => { if (s && !loaded) load() }, { immediate: true })

const changed = computed(() => loaded && Object.keys(loaded).some(k => Number(draft[k]) !== loaded[k]))

function apply() {
  setServiceSettings({
    $bugEmRealism: draft.realism,
    $bugEmFaultRate: draft.faultRatePct / 100,
    $bugEmParkedSim: draft.parkedSimPct / 100,
    $bugEmStartBattery: draft.startBatteryPct / 100,
    $bugEmStartOilKm: draft.startOilKm,
  })
  loaded = null  // re-read after the respawn
}
</script>

<style lang="scss" scoped>
.es {
  display: flex;
  flex-direction: column;
  gap: 1.1em;
  padding: 0.5em 0.25em;
  color: var(--bng-off-white, #eee);
}
h3 { margin: 0 0 0.5em; font-size: 1.05em; }
label { display: block; opacity: 0.75; margin: 0.5em 0 0.2em; }
.es-note { opacity: 0.8; line-height: 1.4; margin: 0; }
.seg { display: flex; flex-wrap: wrap; gap: 0.4em; }
.actions { display: flex; gap: 0.5em; }
</style>

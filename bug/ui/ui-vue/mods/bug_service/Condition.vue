<template>
  <div class="em">
    <div v-if="!state" class="em-empty">
      No data yet. Sit in a Bug (or switch to one) and let the simulation run for a second.
    </div>

    <template v-else>
      <section>
        <h3>Engine <span class="tag real">real</span></h3>
        <div class="grid">
          <span>Ignition</span><b>{{ ["off", "accessory", "on", "start"][state.live.ignitionLevel] ?? state.live.ignitionLevel }}</b>
          <span>Engine speed</span><b>{{ fmt.num(state.live.rpm, 0, "rpm") }}</b>
          <span>Oil temperature</span><b>{{ fmt.num(state.live.oilTempC, 0, "°C") }}</b>
          <span>Engine temperature</span><b>{{ fmt.num(state.live.engineTempC, 0, "°C") }}</b>
          <span>Oil pressure</span><b>{{ fmt.num(state.live.oilPressure, 1, "psi") }}</b>
        </div>
      </section>

      <section v-if="state.battery">
        <h3>Electrics <span class="tag real">real</span></h3>
        <div class="bar"><div class="bar-fill" :style="{ width: (state.battery.charge * 100) + '%' }" /></div>
        <div class="grid">
          <span>Battery charge</span><b>{{ fmt.pct(state.battery.charge, 1) }}</b>
          <span>Voltage</span><b>{{ fmt.num(state.battery.voltage, 2, "V") }}</b>
          <span>Current</span><b>{{ fmt.num(state.battery.current, 1, "A") }}</b>
          <span>Charging</span><b>{{ state.battery.charging ? "yes" : "no" }}</b>
          <span>Charge light</span><b>{{ state.live.generatorLow ? "on" : "off" }}</b>
        </div>
      </section>

      <section>
        <h3>Mileage <span class="tag real">real</span></h3>
        <div class="grid">
          <span>Car (root part)</span><b>{{ fmt.km(state.odometers.root) }}</b>
          <template v-for="p in state.odometers.parts" :key="p.id">
            <span class="mono">{{ p.id }}</span><b>{{ fmt.km(p.odometer) }}</b>
          </template>
        </div>
        <div v-if="state.odometers.note" class="em-note small">{{ state.odometers.note }}</div>
      </section>

      <section>
        <h3>Standing time <span class="tag real">real clock</span> <span class="tag preview">preview only</span></h3>
        <div v-if="!state.parked.lastSeen" class="em-note">
          First session with this concept: nothing recorded yet. "Last seen" is written every 30 s while you sit in
          the car. Respawn or restart the game later to see the standing time.
        </div>
        <div v-else class="grid">
          <span>Last seen</span><b>{{ fmt.date(state.parked.lastSeen) }}</b>
          <span>Stood for</span><b>{{ fmt.duration(state.parked.seconds) }}</b>
          <template v-if="state.parked.preview">
            <span>Simulated (settings)</span><b>{{ fmt.duration(state.parked.preview.simulatedSeconds) }} at {{ fmt.num(state.parked.preview.tempC, 0, "°C") }}</b>
            <span>Battery self-discharge</span>
            <b>{{ fmt.pct(state.parked.preview.chargeBefore, 1) }} → {{ fmt.pct(state.parked.preview.chargeAfter, 1) }}</b>
          </template>
        </div>
        <div class="em-note small">
          Closed form SoC·e<sup>−k(T)·t</sup>, k = 3 %/month at 20 °C, doubling every 10 K. Not applied to the car.
        </div>
      </section>

      <section>
        <h3>Model state <span class="tag mock">mock</span></h3>
        <div class="grid">
          <template v-for="row in mockState" :key="row[0]">
            <span>{{ row[0] }}</span><b>{{ row[1] }}</b>
          </template>
        </div>
      </section>
    </template>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { useServiceState, fmt } from "./useServiceState.js"

const { state } = useServiceState()

// placeholder values: what the engine model's subsystems will report later
const mockState = computed(() => [
  ["Oil age", fmt.num(state.value?.settings?.startOilKm ?? 0, 0, "km") + " (start setting)"],
  ["Oil level", "2.3 / 2.5 L"],
  ["Points gap", "0.38 mm (spec 0.40)"],
  ["Dwell angle", "52°"],
  ["Valve clearance, cyl. 3 exhaust", "0.08 mm (spec 0.10)"],
  ["Fan belt wear", "35 %"],
  ["Spark plugs", "light fouling"],
  ["Carbon deposits", "low"],
  ["Engine hours", "412 h"],
  ["Cold starts", "1,208"],
])
</script>

<style lang="scss" scoped>
.em {
  display: flex;
  flex-direction: column;
  gap: 1.1em;
  padding: 0.5em 0.25em;
  color: var(--bng-off-white, #eee);
}
h3 {
  margin: 0 0 0.4em;
  font-size: 1.05em;
  display: flex;
  align-items: center;
  gap: 0.5em;
}
.grid {
  display: grid;
  grid-template-columns: minmax(10em, 1fr) auto;
  gap: 0.25em 1.5em;
  span { opacity: 0.75; }
  b { font-weight: 600; text-align: right; font-variant-numeric: tabular-nums; }
}
.mono { font-family: monospace; font-size: 0.85em; }
.tag {
  font-size: 0.65em;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  padding: 0.1em 0.5em;
  border-radius: 0.3em;
  &.real { background: rgba(0, 158, 115, 0.35); }
  &.mock { background: rgba(230, 159, 0, 0.4); }
  &.preview { background: rgba(86, 180, 233, 0.35); }
}
.bar {
  height: 0.5em;
  border-radius: 0.25em;
  background: rgba(255, 255, 255, 0.12);
  margin-bottom: 0.5em;
  overflow: hidden;
}
.bar-fill { height: 100%; background: rgb(0, 158, 115); }
.em-empty, .em-note { opacity: 0.8; line-height: 1.4; }
.small { font-size: 0.85em; margin-top: 0.4em; opacity: 0.6; }
</style>

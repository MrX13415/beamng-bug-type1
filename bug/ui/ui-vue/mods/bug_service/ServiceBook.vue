<template>
  <div class="sb">
    <p class="sb-note">
      <span class="tag">mock</span> In the full design this is a booklet in the glovebox, next to the owner's
      manual, and belongs to one car. It is shown here to compare the two places: pause menu or the book in the car.
    </p>

    <div class="sb-page">
      <div class="sb-head">
        <div class="sb-title">Service Record</div>
        <div class="sb-sub">1200 · Engine no. D 0 412 337</div>
      </div>
      <table>
        <thead>
          <tr><th>Date</th><th>km</th><th>Work done</th><th>Sign.</th></tr>
        </thead>
        <tbody>
          <tr v-for="e in entries" :key="e.km + e.work">
            <td>{{ e.date }}</td><td class="num">{{ e.km.toLocaleString() }}</td><td>{{ e.work }}</td><td class="sig">{{ e.sig }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>

<script setup>
const entries = [
  { date: "12.03.63", km: 500,   work: "Run-in service: oil change, valve clearance, points", sig: "Dealer" },
  { date: "02.07.63", km: 2500,  work: "Oil change (HD 30), lubrication", sig: "Dealer" },
  { date: "19.11.63", km: 5000,  work: "Oil change, points gap 0.40 mm, timing 10° BTDC", sig: "Dealer" },
  { date: "04.02.64", km: 6120,  work: "Fan belt replaced (roadside, spare from frunk)", sig: "owner" },
  { date: "28.05.64", km: 7500,  work: "Oil change, spark plugs replaced, idle set", sig: "owner" },
]
</script>

<style lang="scss" scoped>
.sb { display: flex; flex-direction: column; gap: 1em; padding: 0.5em 0.25em; color: var(--bng-off-white, #eee); }
.sb-note { opacity: 0.8; line-height: 1.4; margin: 0; }
.tag {
  font-size: 0.65em; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em;
  padding: 0.1em 0.5em; border-radius: 0.3em; background: rgba(230, 159, 0, 0.4);
}
.sb-page {
  background: linear-gradient(#f3ead6, #e9dcc0);
  color: #2b2418;
  border-radius: 0.3em;
  padding: 1.2em 1.4em;
  font-family: Georgia, "Times New Roman", serif;
  box-shadow: 0 0.3em 1em rgba(0, 0, 0, 0.4);
}
.sb-head { border-bottom: 2px solid #2b2418; margin-bottom: 0.8em; padding-bottom: 0.4em; }
.sb-title { font-size: 1.5em; font-weight: 700; letter-spacing: 0.04em; }
.sb-sub { font-size: 0.85em; opacity: 0.75; }
table { width: 100%; border-collapse: collapse; font-size: 0.9em; }
th { text-align: left; font-weight: 700; border-bottom: 1px solid rgba(43, 36, 24, 0.6); padding: 0.3em 0.4em; }
td { border-bottom: 1px dotted rgba(43, 36, 24, 0.4); padding: 0.35em 0.4em; vertical-align: top; }
.num { text-align: right; font-variant-numeric: tabular-nums; }
.sig { font-style: italic; color: #1d3c7a; white-space: nowrap; }
</style>

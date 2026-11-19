// Work mode at the engine bay (proof of concept): registers the see-through route "bug.worktop" (Worktop.vue).
//
// The route is opened from Lua by the GE extension bug_worktop (lua/ge/extensions/bug/worktop.lua) after a click on
// the carburettor. The page only draws the tool bar at the bottom; everything else lets the mouse through to the
// game (pointer-events: none), so the cursor can point at the screws in the 3D view. Leaving the route (Esc / back)
// ends the work mode: bug_worktop notices that its route is gone.
//
// Registered twice, as described in ui/ui-vue/mods/README.md of the game: Vue gets the component, Lua gets the
// navigable route configuration.

import { useBridge } from "@/bridge"
import Worktop from "./Worktop.vue"

const SOURCE_ID = "bug_worktop.routes"

const routes = [
  {
    path: "/bug-worktop",
    name: "bug.worktop",   // must match ROUTE_NAME in lua/ge/extensions/bug/worktop.lua
    component: Worktop,
    meta: {
      uiTypes: ["vue"],
      uiTypesFilter: "only",
      infoBar: { visible: false, showSysInfo: false },
      topBar: { visible: false },
      uiApps: { shown: false },
      luaRoute: {
        title: "Work Mode",
        backTarget: "play",
      },
    },
  },
]

function toLuaRoutes(records) {
  return records.map(record => ({
    name: record.name,
    path: record.path,
    meta: record.meta,
    ...(record.children ? { children: toLuaRoutes(record.children) } : {}),
  }))
}

export async function onLoad() {
  const { lua } = useBridge()
  window.bngRoutes.add([{ path: SOURCE_ID, routes }])
  const result = await lua.extensions.ui_router_routeManager.registerModRoutes(SOURCE_ID, toLuaRoutes(routes))
  if (!result?.success) {
    window.bngRoutes.remove([SOURCE_ID])
    console.error("[bug_worktop] Failed to register the work mode route", result?.errors)
  }
}

export async function onUnload() {
  const { lua } = useBridge()
  window.bngRoutes.remove([SOURCE_ID])
  await lua.extensions.ui_router_routeManager.unregisterModRoutes(SOURCE_ID, { fallbackRoute: "play" })
}

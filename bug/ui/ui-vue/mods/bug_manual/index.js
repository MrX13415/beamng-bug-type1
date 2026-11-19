// Owner's manual of the Bug: registers the full-screen route "bug.manual" (page: BugManual.vue).
//
// The route is opened from Lua: a click on the book in the open glovebox runs vehicle.openManual
// (vehicles/bug/lua/vehicle.lua), which calls bug_manual.open() (lua/ge/extensions/bug/manual.lua).
// That extension goes back to the previous route on close. The game keeps running while it is open.
//
// Registered twice, as described in ui/ui-vue/mods/README.md of the game: Vue gets the component,
// Lua gets the navigable route configuration.

import { useBridge } from "@/bridge"
import BugManual from "./BugManual.vue"

const SOURCE_ID = "bug_manual.routes"

const routes = [
  {
    path: "/bug-manual",
    name: "bug.manual",   // must match ROUTE_NAME in lua/ge/extensions/bug/manual.lua
    component: BugManual,
    meta: {
      uiTypes: ["vue"],
      uiTypesFilter: "only",
      infoBar: { visible: false, showSysInfo: false },
      topBar: { visible: false },
      uiApps: { shown: false },
      luaRoute: {
        title: "Owner's Manual",
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
    console.error("[bug_manual] Failed to register the owner's manual route", result?.errors)
  }
}

export async function onUnload() {
  const { lua } = useBridge()
  window.bngRoutes.remove([SOURCE_ID])
  await lua.extensions.ui_router_routeManager.unregisterModRoutes(SOURCE_ID, { fallbackRoute: "play" })
}

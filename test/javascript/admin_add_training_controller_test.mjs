import { test, beforeEach, after } from "node:test"
import assert from "node:assert/strict"
import { JSDOM } from "jsdom"

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost" })

for (const name of ["document", "Node", "Element", "HTMLElement", "MutationObserver", "Event",
                    "CustomEvent", "ErrorEvent", "SubmitEvent", "KeyboardEvent", "MouseEvent"]) {
  global[name] = dom.window[name]
}
global.window = dom.window

const { Application } = await import("@hotwired/stimulus")
const { default: AdminAddTrainingController } =
  await import("../../app/javascript/controllers/admin_add_training_controller.js")

const application = new Application(dom.window.document.documentElement)
application.handleError = (error) => { throw error }
application.register("admin-add-training", AdminAddTrainingController)
await application.start()

after(() => application.stop())

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

function buildMenu() {
  const menu = dom.window.document.createElement("div")
  menu.dataset.controller = "admin-add-training"
  menu.innerHTML = `
    <select data-admin-add-training-target="trainer">
      <option value="1">Admin</option>
      <option value="9" selected>Ada Trainer</option>
    </select>
    <form id="laser" data-action="submit->admin-add-training#stamp">
      <input type="hidden" name="trainer_id" value="1">
      <button type="submit">Laser Cutting</button>
    </form>
    <form id="wood" data-action="submit->admin-add-training#stamp">
      <input type="hidden" name="trainer_id" value="1">
      <button type="submit">Woodworking</button>
    </form>
  `
  dom.window.document.body.appendChild(menu)
  return menu
}

beforeEach(() => {
  dom.window.document.body.innerHTML = ""
})

test("stamps the chosen trainer onto the form that submits", async () => {
  const menu = buildMenu()
  await settle()

  const laser = menu.querySelector("#laser")
  const wood = menu.querySelector("#wood")
  laser.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }))

  assert.equal(laser.querySelector("input[name='trainer_id']").value, "9")
  assert.equal(wood.querySelector("input[name='trainer_id']").value, "1")
})

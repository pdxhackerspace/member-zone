import { test, beforeEach, after } from "node:test"
import assert from "node:assert/strict"
import { JSDOM } from "jsdom"

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost" })

// Stimulus and the controller both reach for browser globals at import time.
for (const name of ["document", "Node", "Element", "HTMLElement", "MutationObserver", "Event",
                    "CustomEvent", "ErrorEvent", "SubmitEvent", "KeyboardEvent", "MouseEvent"]) {
  global[name] = dom.window[name]
}
global.window = dom.window

// Stands in for bootstrap.Modal: show/hide only, with the hidden event the controller
// waits on before submitting.
class FakeModal {
  static instances = new Map()

  static getOrCreateInstance(element) {
    if (!this.instances.has(element)) this.instances.set(element, new FakeModal(element))
    return this.instances.get(element)
  }

  constructor(element) {
    this.element = element
    this.shown = false
    this.showCount = 0
  }

  show() {
    this.shown = true
    this.showCount += 1
  }

  hide() {
    if (!this.shown) return
    this.shown = false
    this.element.dispatchEvent(new dom.window.Event("hidden.bs.modal"))
  }
}

dom.window.bootstrap = { Modal: FakeModal }

const { Application } = await import("@hotwired/stimulus")
const { default: InactiveTrainingNoticeController } =
  await import("../../app/javascript/controllers/inactive_training_notice_controller.js")

const application = new Application(dom.window.document.documentElement)
application.handleError = (error) => { throw error }
application.register("inactive-training-notice", InactiveTrainingNoticeController)
await application.start()

after(() => application.stop())

// Stimulus connects controllers through a MutationObserver, so give it a turn.
const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

function buildForm(names) {
  const form = dom.window.document.createElement("form")
  form.method = "post"
  form.action = "/train/1/add/2"
  form.dataset.controller = "inactive-training-notice"
  form.dataset.action = "submit->inactive-training-notice#confirm"
  form.dataset.inactiveTrainingNoticeNamesValue = JSON.stringify(names)

  const button = dom.window.document.createElement("button")
  button.type = "submit"
  form.appendChild(button)

  // jsdom has no form submission, so stand in for it and keep dispatching the submit
  // event that a real requestSubmit would.
  form.submissions = []
  form.requestSubmit = () => {
    const event = new dom.window.Event("submit", { bubbles: true, cancelable: true })
    form.dispatchEvent(event)
    if (event.defaultPrevented) return
    form.submissions.push(form.querySelector("input[name='notify_inactive']")?.value ?? null)
  }

  dom.window.document.body.appendChild(form)
  return form
}

function modalElement() {
  return dom.window.document.getElementById("inactiveTrainingNoticeModal")
}

function clickModal(role) {
  modalElement().querySelector(`[data-role='${role}']`)
    .dispatchEvent(new dom.window.Event("click", { bubbles: true }))
}

beforeEach(() => {
  dom.window.document.body.innerHTML = ""
  FakeModal.instances.clear()
})

test("submits straight through when no trainee is inactive", async () => {
  const form = buildForm([])
  await settle()

  form.requestSubmit()

  assert.equal(modalElement(), null)
  assert.deepEqual(form.submissions, [null])
})

test("records the trainer's answer and submits once", async () => {
  const form = buildForm(["Jane Doe"])
  await settle()

  form.requestSubmit()
  assert.equal(form.submissions.length, 0, "submit is held until the trainer answers")

  clickModal("notify")

  assert.deepEqual(form.submissions, ["1"])
})

test("submits without notifying when the trainer declines", async () => {
  const form = buildForm(["Jane Doe"])
  await settle()

  form.requestSubmit()
  clickModal("skip")

  assert.deepEqual(form.submissions, ["0"])
})

test("cancelling the prompt records nothing", async () => {
  const form = buildForm(["Jane Doe"])
  await settle()

  form.requestSubmit()
  FakeModal.getOrCreateInstance(modalElement()).hide()

  assert.deepEqual(form.submissions, [])
})

// Regression: #ask used to add a fresh pair of button listeners every time it ran, so a
// second submit arriving while the prompt was open made one answer submit twice.
test("a second submit while the prompt is open does not stack listeners", async () => {
  const form = buildForm(["Jane Doe"])
  await settle()

  form.requestSubmit()
  form.requestSubmit()
  form.requestSubmit()

  assert.equal(FakeModal.getOrCreateInstance(modalElement()).showCount, 1)

  clickModal("notify")

  assert.deepEqual(form.submissions, ["1"])
})

// The modal is shared across every form on the page, so listeners left behind by one
// form would otherwise fire for another.
test("a second form cannot be submitted by another form's prompt", async () => {
  const first = buildForm(["Jane Doe"])
  const second = buildForm(["Rex Roe"])
  await settle()

  first.requestSubmit()
  second.requestSubmit()
  clickModal("notify")

  assert.deepEqual(first.submissions, ["1"])
  assert.deepEqual(second.submissions, [])

  second.requestSubmit()
  clickModal("skip")

  assert.deepEqual(second.submissions, ["0"])
})

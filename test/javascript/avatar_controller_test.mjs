import { test, beforeEach, after } from "node:test"
import assert from "node:assert/strict"
import { JSDOM } from "jsdom"

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost" })
for (const name of ["document", "Node", "Element", "HTMLElement", "MutationObserver", "Event",
                    "KeyboardEvent", "MouseEvent"]) {
  global[name] = dom.window[name]
}
global.window = dom.window

const { Application } = await import("@hotwired/stimulus")
const { default: AvatarController } = await import("../../app/javascript/controllers/avatar_controller.js")
const application = new Application(dom.window.document.documentElement)
application.handleError = (error) => { throw error }
application.register("avatar", AvatarController)
await application.start()
after(() => application.stop())
beforeEach(() => { document.body.innerHTML = "" })

const photo = "https://avatars.slack-edge.com/photo.png"
const gravatar = "https://www.gravatar.com/avatar/example?s=44&d=mp"
const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

async function buildImage({ complete = false, naturalWidth = 0, fallback = gravatar } = {}) {
  const image = document.createElement("img")
  image.src = photo
  image.dataset.controller = "avatar"
  image.dataset.action = "error->avatar#fallback"
  if (fallback) image.dataset.avatarFallbackUrlValue = fallback
  Object.defineProperties(image, {
    complete: { value: complete },
    naturalWidth: { value: naturalWidth }
  })
  document.body.appendChild(image)
  await settle()
  return image
}

test("failed photo switches to Gravatar without retrying a failed Gravatar", async () => {
  const image = await buildImage()
  assert.equal(image.src, photo)
  image.dispatchEvent(new Event("error"))
  assert.equal(image.src, gravatar)

  const mutations = []
  const observer = new MutationObserver((records) => mutations.push(...records))
  observer.observe(image, { attributes: true, attributeFilter: ["src"] })
  image.dispatchEvent(new Event("error"))
  await settle()
  observer.disconnect()
  assert.equal(mutations.length, 0)
})

test("handles an image that failed before the controller connected", async () => {
  const image = await buildImage({ complete: true })
  assert.equal(image.src, gravatar)
})

test("keeps successfully loaded photos", async () => {
  const image = await buildImage({ complete: true, naturalWidth: 192 })
  assert.equal(image.src, photo)
})

test("does not set an empty source when there is no email fallback", async () => {
  const image = await buildImage({ fallback: null })
  image.dispatchEvent(new Event("error"))
  assert.equal(image.src, photo)
})

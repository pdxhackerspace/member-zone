import { Controller } from "@hotwired/stimulus"

// Inactive members can be trained, but they should not silently receive a "you're trained"
// email for a space they currently cannot enter. This intercepts the submit and asks the
// trainer, then submits with notify_inactive set either way.
//
// Attach to the form and list the inactive trainees by name. Pages that build their
// selection client-side can rewrite the value as the selection changes; with no names the
// form submits untouched.
//
//   <form data-controller="inactive-training-notice"
//         data-action="submit->inactive-training-notice#confirm"
//         data-inactive-training-notice-names-value='["Jane Doe"]'>

const MODAL_ID = "inactiveTrainingNoticeModal"

export default class extends Controller {
  static values = { names: { type: Array, default: [] } }

  confirm(event) {
    if (this.answered || this.namesValue.length === 0) return

    event.preventDefault()
    this.#ask()
  }

  #ask() {
    const modalElement = this.#modalElement()
    modalElement.querySelector("[data-role='names']").textContent = this.#subject()

    const modal = window.bootstrap.Modal.getOrCreateInstance(modalElement)
    const notify = modalElement.querySelector("[data-role='notify']")
    const skip = modalElement.querySelector("[data-role='skip']")
    let answer = null

    const onNotify = () => { answer = "1"; modal.hide() }
    const onSkip = () => { answer = "0"; modal.hide() }

    // Cleanup runs on cancel too, so a dismissed modal leaves no listener behind that a
    // later form on the same page would trip over.
    const cleanup = () => {
      notify.removeEventListener("click", onNotify)
      skip.removeEventListener("click", onSkip)
      modalElement.removeEventListener("hidden.bs.modal", cleanup)
      if (answer !== null) this.#submitWith(answer)
    }

    notify.addEventListener("click", onNotify)
    skip.addEventListener("click", onSkip)
    modalElement.addEventListener("hidden.bs.modal", cleanup)
    modal.show()
  }

  #submitWith(value) {
    let field = this.element.querySelector("input[name='notify_inactive']")
    if (!field) {
      field = document.createElement("input")
      field.type = "hidden"
      field.name = "notify_inactive"
      this.element.appendChild(field)
    }
    field.value = value

    this.answered = true
    this.element.requestSubmit()
  }

  #subject() {
    const names = this.namesValue
    if (names.length === 1) return `${names[0]} is not an active member.`
    if (names.length === 2) return `${names[0]} and ${names[1]} are not active members.`

    return `${names.length} of the selected members are not active.`
  }

  // One modal is shared by every form on the page — the profile page alone renders one
  // form per untrained topic.
  #modalElement() {
    const existing = document.getElementById(MODAL_ID)
    if (existing) return existing

    const wrapper = document.createElement("div")
    wrapper.innerHTML = `
      <div class="modal fade" id="${MODAL_ID}" tabindex="-1" aria-hidden="true">
        <div class="modal-dialog modal-dialog-centered">
          <div class="modal-content">
            <div class="modal-header">
              <h5 class="modal-title">Notify about this training?</h5>
              <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" aria-label="Close"></button>
            </div>
            <div class="modal-body">
              <p class="text-13 fw-medium mb-1" data-role="names"></p>
              <p class="text-13 text-secondary mb-0">
                The training will be recorded either way. Should they get an email saying so?
              </p>
            </div>
            <div class="modal-footer">
              <button type="button" class="btn btn-outline-secondary btn-sm" data-bs-dismiss="modal">Cancel</button>
              <button type="button" class="btn btn-outline-secondary btn-sm" data-role="skip">Record without email</button>
              <button type="button" class="btn btn-primary btn-sm" data-role="notify">Record and email</button>
            </div>
          </div>
        </div>
      </div>
    `.trim()

    const modalElement = wrapper.firstElementChild
    document.body.appendChild(modalElement)
    return modalElement
  }
}

import { Controller } from "@hotwired/stimulus"

// A few decisions are offered to administrators so the organization is never stuck, but
// belong to a role holder in the ordinary course — approving a membership application is
// the executive director's call. When an admin only sees the button because of the is_admin
// bypass, this intercepts the submit and makes them say out loud that they mean it.
//
// A plain confirm() is too easy to click through for this, so the prompt is a modal whose
// button stays disabled until the acknowledgement is checked.
//
//   <form data-controller="admin-override-confirm"
//         data-action="submit->admin-override-confirm#guard"
//         data-admin-override-confirm-heading-value="Approve without the approver role?"
//         data-admin-override-confirm-body-value="Approving is normally the ED's decision."
//         data-admin-override-confirm-acknowledge-value="Yes, and it's okay to do it now."
//         data-admin-override-confirm-confirm-label-value="Approve anyway">

const MODAL_ID = "adminOverrideConfirmModal"

export default class extends Controller {
  static values = {
    heading: { type: String, default: "Are you sure?" },
    body: { type: String, default: "" },
    acknowledge: { type: String, default: "I understand and want to continue." },
    confirmLabel: { type: String, default: "Continue" }
  }

  guard(event) {
    if (this.acknowledged) return

    event.preventDefault()
    this.#ask()
  }

  #ask() {
    const modalElement = this.#modalElement()

    // The modal is shared by every form on the page, so a second submit arriving while a
    // prompt is already open must not stack another set of listeners — one answer would
    // otherwise submit more than once.
    if (modalElement.dataset.prompting === "true") return

    modalElement.dataset.prompting = "true"
    modalElement.querySelector("[data-role='heading']").textContent = this.headingValue
    modalElement.querySelector("[data-role='body']").textContent = this.bodyValue
    modalElement.querySelector("[data-role='acknowledge-label']").textContent = this.acknowledgeValue

    const modal = window.bootstrap.Modal.getOrCreateInstance(modalElement)
    const acknowledge = modalElement.querySelector("[data-role='acknowledge']")
    const proceed = modalElement.querySelector("[data-role='proceed']")
    let confirmed = false

    acknowledge.checked = false
    proceed.disabled = true
    proceed.textContent = this.confirmLabelValue

    const onToggle = () => { proceed.disabled = !acknowledge.checked }
    const onProceed = () => { confirmed = true; modal.hide() }

    // Cleanup runs on cancel too, so a dismissed modal leaves no listener behind for a
    // later submit to trip over.
    const cleanup = () => {
      delete modalElement.dataset.prompting
      acknowledge.removeEventListener("change", onToggle)
      proceed.removeEventListener("click", onProceed)
      modalElement.removeEventListener("hidden.bs.modal", cleanup)
      if (confirmed) this.#submit()
    }

    acknowledge.addEventListener("change", onToggle)
    proceed.addEventListener("click", onProceed)
    modalElement.addEventListener("hidden.bs.modal", cleanup)
    modal.show()
  }

  #submit() {
    this.acknowledged = true
    this.element.requestSubmit()
  }

  #modalElement() {
    const existing = document.getElementById(MODAL_ID)
    if (existing) return existing

    const wrapper = document.createElement("div")
    wrapper.innerHTML = `
      <div class="modal fade" id="${MODAL_ID}" tabindex="-1" aria-hidden="true">
        <div class="modal-dialog modal-dialog-centered">
          <div class="modal-content">
            <div class="modal-header">
              <h5 class="modal-title" data-role="heading"></h5>
              <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" aria-label="Close"></button>
            </div>
            <div class="modal-body">
              <p class="text-13 mb-3" data-role="body"></p>
              <div class="form-check">
                <input class="form-check-input" type="checkbox" id="${MODAL_ID}Acknowledge" data-role="acknowledge">
                <label class="form-check-label text-13" for="${MODAL_ID}Acknowledge" data-role="acknowledge-label"></label>
              </div>
            </div>
            <div class="modal-footer">
              <button type="button" class="btn btn-outline-secondary btn-sm" data-bs-dismiss="modal">Cancel</button>
              <button type="button" class="btn btn-danger btn-sm" data-role="proceed" disabled></button>
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

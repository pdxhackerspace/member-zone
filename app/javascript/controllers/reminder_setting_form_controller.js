import { Controller } from "@hotwired/stimulus"

// Auto-saves reminder toggles on change and keeps the enabled label in sync with the switch.
export default class extends Controller {
  static targets = ["enabledInput", "enabledLabel"]

  submit(event) {
    if (this.hasEnabledInputTarget && event.target === this.enabledInputTarget) {
      this.enabledLabelTarget.textContent = this.enabledInputTarget.checked ? "Enabled" : "Disabled"
    }
    this.element.requestSubmit()
  }
}

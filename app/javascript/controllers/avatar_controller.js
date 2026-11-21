import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { fallbackUrl: String }

  connect() {
    // The image may have failed before Stimulus attached its error listener.
    if (this.element.complete && this.element.naturalWidth === 0) this.fallback()
  }

  fallback() {
    if (this.hasFallbackUrlValue && this.fallbackUrlValue && this.element.src !== this.fallbackUrlValue) {
      this.element.src = this.fallbackUrlValue
    }
  }
}

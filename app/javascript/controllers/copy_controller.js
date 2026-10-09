import { Controller } from "@hotwired/stimulus"

// Copies the value of a field to the clipboard and says so on the button.
//
//   <div data-controller="copy">
//     <input readonly value="..." data-copy-target="source">
//     <button type="button" data-action="copy#copy" data-copy-target="button">Copy</button>
//   </div>
export default class extends Controller {
  static targets = ["source", "button"]

  copy() {
    const label = this.buttonTarget.textContent
    navigator.clipboard.writeText(this.sourceTarget.value).then(() => {
      this.buttonTarget.textContent = "Copied"
      setTimeout(() => { this.buttonTarget.textContent = label }, 2000)
    })
  }
}

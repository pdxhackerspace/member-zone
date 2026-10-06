import { Controller } from "@hotwired/stimulus"

// Multi-select member picker. Pairs with the live-filter controller declared on
// the same element: live-filter owns the search box and which results are
// visible, this owns selection — the hidden inputs the form submits, the badge
// list, and the "Added" marker on each result row.
//
// The hidden inputs are the source of truth, so a form redisplayed after a
// validation failure keeps its selections without any extra server-side markup.
//
//   <div data-controller="live-filter member-picker"
//        data-live-filter-min-length-value="2"
//        data-member-picker-field-name-value="model[member_ids][]">
export default class extends Controller {
  static targets = ["search", "selected", "inputs", "result", "empty", "template", "resultsContainer", "noResults"]
  static values = {
    fieldName: String,
    searchUrl: String,
    searchMinLength: { type: Number, default: 1 }
  }

  connect() {
    this.selectedTarget.replaceChildren()
    this._hiddenInputs().forEach((input) => {
      this.selectedTarget.appendChild(this._badge(input.value, input.dataset.userName || input.value))
    })
    this._sync()
  }

  add({ params }) {
    const id = String(params.id)
    if (this._selectedIds().has(id)) return

    const input = document.createElement("input")
    input.type = "hidden"
    input.name = this.fieldNameValue
    input.value = id
    input.dataset.userName = params.name
    this.inputsTarget.appendChild(input)

    this.selectedTarget.appendChild(this._badge(id, params.name))
    this._sync()
    this._resetSearch()
  }

  remove({ params }) {
    const id = String(params.id)

    this._hiddenInputs().forEach((input) => { if (input.value === id) input.remove() })
    this.selectedTarget
      .querySelectorAll(`[data-user-id="${CSS.escape(id)}"]`)
      .forEach((badge) => badge.remove())

    this._sync()
  }

  _badge(id, name) {
    const badge = this.templateTarget.content.firstElementChild.cloneNode(true)

    badge.dataset.userId = id
    badge.querySelector("[data-member-name]").textContent = name
    badge.querySelector("button").dataset.memberPickerIdParam = id

    return badge
  }

  // The always-present blank input lets the form clear every selection; it is
  // never a real member.
  _hiddenInputs() {
    return Array.from(this.inputsTarget.querySelectorAll("input[type=hidden]"))
      .filter((input) => input.value !== "")
  }

  _selectedIds() {
    return new Set(this._hiddenInputs().map((input) => input.value))
  }

  _sync() {
    const selected = this._selectedIds()

    this.resultTargets.forEach((row) => {
      const added = selected.has(row.dataset.userId)
      row.classList.toggle("opacity-50", added)
      row.querySelector("[data-member-added]")?.classList.toggle("d-none", !added)
    })

    this.emptyTarget.classList.toggle("d-none", selected.size > 0)
  }

  _resetSearch() {
    this.searchTarget.value = ""
    // Hands control of result visibility back to live-filter rather than
    // hiding the list here.
    this.searchTarget.dispatchEvent(new Event("input", { bubbles: true }))
    if (this.hasResultsContainerTarget) {
      this.resultsContainerTarget.classList.add("d-none")
      // Server search builds rows in JS; admin live-filter keeps its roster in the DOM.
      if (this.searchUrlValue) {
        this.resultsContainerTarget.replaceChildren()
      }
    }
    if (this.hasNoResultsTarget) {
      this.noResultsTarget.classList.add("d-none")
    }
    this.searchTarget.focus()
  }

  queryServer() {
    if (!this.searchUrlValue) return

    clearTimeout(this.serverSearchTimeout)
    this.serverSearchTimeout = setTimeout(() => this._runServerSearch(), 250)
  }

  async _runServerSearch() {
    const term = this.searchTarget.value.trim()
    if (term.length < this.searchMinLengthValue) {
      if (this.hasResultsContainerTarget) {
        this.resultsContainerTarget.classList.add("d-none")
        this.resultsContainerTarget.replaceChildren()
      }
      if (this.hasNoResultsTarget) this.noResultsTarget.classList.add("d-none")
      return
    }

    const response = await fetch(`${this.searchUrlValue}?q=${encodeURIComponent(term)}`, {
      headers: { Accept: "application/json" }
    })
    if (!response.ok) return

    const users = await response.json()
    this._renderServerResults(users)
  }

  _renderServerResults(users) {
    if (!this.hasResultsContainerTarget) return

    this.resultsContainerTarget.replaceChildren()
    const selected = this._selectedIds()

    users.forEach((user) => {
      const row = document.createElement("div")
      row.className = "search-result-item p-2 border-bottom d-flex justify-content-between align-items-center"
      row.style.cursor = "pointer"
      row.dataset.memberPickerTarget = "result"
      row.dataset.userId = String(user.id)
      row.dataset.action = "click->member-picker#add"
      row.dataset.memberPickerIdParam = String(user.id)
      row.dataset.memberPickerNameParam = user.username
      row.innerHTML = `
        <div class="fw-medium text-13">${this._escapeHtml(user.username)}</div>
        <span class="badge text-bg-success-subtle d-none" data-member-added>
          <i class="bi bi-check"></i> Added
        </span>
      `
      row.addEventListener("click", () => {
        this.add({ params: { id: user.id, name: user.username } })
      })
      if (selected.has(String(user.id))) {
        row.classList.add("opacity-50")
        row.querySelector("[data-member-added]")?.classList.remove("d-none")
      }
      this.resultsContainerTarget.appendChild(row)
    })

    const visible = users.length > 0
    this.resultsContainerTarget.classList.toggle("d-none", !visible)
    if (this.hasNoResultsTarget) {
      this.noResultsTarget.classList.toggle("d-none", visible)
    }
  }

  _escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}

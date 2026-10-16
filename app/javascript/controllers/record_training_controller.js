import { Controller } from "@hotwired/stimulus"

// The record-training form: pick topics, add members, and choose whether they were trained
// or are being made trainers. Every member row previews what will happen in each selected
// topic, and the action bar totals it, so nothing is skipped by surprise on submit.
//
// Topic chips say which modes the signed-in account may use them for (data-can-record,
// data-can-appoint); a chip the current mode can't use is disabled and dropped from the
// selection. The server re-checks every topic.
export default class extends Controller {
  static targets = [
    "topic", "topicInputs", "topicCount", "topicNote", "search", "results", "members", "memberCount",
    "unresolved", "paste", "mode", "modeHelp", "date", "backdateWarning", "summary", "detail", "submit", "users"
  ]

  static values = {
    initialTraineeIds: Array,
    initialTopicIds: Array,
    recordAs: { type: String, default: "trained" }
  }

  connect() {
    this.users = JSON.parse(this.usersTarget.textContent)
    this.usersById = new Map(this.users.map((user) => [String(user.id), user]))
    this.topicNames = new Map(this.topicTargets.map((chip) => [chip.dataset.topicId, chip.dataset.topicName]))
    this.selectedTopics = new Set(this.initialTopicIdsValue.map(String).filter((id) => this.topicNames.has(id)))
    this.selectedMembers = new Map()
    this.initialTraineeIdsValue.map(String).forEach((id) => {
      if (this.usersById.has(id)) this.selectedMembers.set(id, this.usersById.get(id))
    })

    this.#setupModes()
    this.outsideClick = (event) => { if (!this.element.contains(event.target)) this.#hideResults() }
    document.addEventListener("click", this.outsideClick)
    this.checkDate()
    this.#render()
  }

  disconnect() {
    document.removeEventListener("click", this.outsideClick)
  }

  toggleTopic(event) {
    const id = event.currentTarget.dataset.topicId
    this.selectedTopics.has(id) ? this.selectedTopics.delete(id) : this.selectedTopics.add(id)
    this.#render()
  }

  setMode(event) {
    this.recordAsValue = event.target.value
    this.#render()
  }

  search() {
    const term = this.searchTarget.value.trim().toLowerCase()
    this.#hideResults()
    if (term.length < 2) return

    this.users.filter((user) => this.#label(user).toLowerCase().includes(term)).slice(0, 12).forEach((user) => {
      const added = this.selectedMembers.has(String(user.id))
      const item = this.#el("button", "list-group-item list-group-item-action text-start")
      item.type = "button"
      item.disabled = added
      item.append(
        this.#el("div", "fw-medium text-13", user.name + (added ? " (already in list)" : "")),
        this.#el("div", "text-11 text-secondary", this.#meta(user))
      )
      item.addEventListener("click", () => this.#addMember(user))
      this.resultsTarget.appendChild(item)
    })
    this.resultsTarget.classList.toggle("d-none", this.resultsTarget.children.length === 0)
  }

  processPaste() {
    const entries = this.pasteTarget.value.split(/[\n,]+/).map((entry) => entry.trim()).filter(Boolean)
    const unresolved = []

    entries.forEach((entry) => {
      const wanted = entry.toLowerCase().replace(/^@/, "")
      const match = this.users.find((user) =>
        [user.username, user.email, user.name].some((value) => (value || "").toLowerCase() === wanted))
      match ? this.selectedMembers.set(String(match.id), match) : unresolved.push(entry)
    })

    this.unresolvedTarget.textContent = `${unresolved.length} couldn't be matched: ${unresolved.join(", ")}`
    this.unresolvedTarget.classList.toggle("d-none", unresolved.length === 0)
    this.pasteTarget.value = ""
    this.#render()
  }

  checkDate() {
    const picked = new Date(`${this.dateTarget.value}T00:00:00`)
    const daysOld = (new Date() - picked) / 86_400_000
    this.backdateWarningTarget.classList.toggle("d-none", !(daysOld > 30))
  }

  guard(event) {
    if (this.submitTarget.disabled) event.preventDefault()
  }

  get trainerMode() {
    return this.recordAsValue === "trainer"
  }

  // The server renders the Trained/Trainer choice only for an account that can appoint
  // trainers somewhere, and disables Trained for one that records nothing itself.
  #setupModes() {
    const available = this.modeTargets.filter((radio) => !radio.disabled).map((radio) => radio.value)
    if (available.length === 0) this.recordAsValue = "trained"
    else if (!available.includes(this.recordAsValue)) this.recordAsValue = available[0]

    this.modeTargets.forEach((radio) => { radio.checked = radio.value === this.recordAsValue })
  }

  #topicAllowed(chip) {
    return chip.dataset[this.trainerMode ? "canAppoint" : "canRecord"] === "true"
  }

  #addMember(user) {
    this.selectedMembers.set(String(user.id), user)
    this.searchTarget.value = ""
    this.#hideResults()
    this.#render()
    this.searchTarget.focus()
  }

  #render() {
    this.#renderTopics()
    const totals = this.#renderMembers()
    this.#renderSummary(totals)
  }

  #renderTopics() {
    let blocked = 0
    this.topicTargets.forEach((chip) => {
      const id = chip.dataset.topicId
      const allowed = this.#topicAllowed(chip)
      if (!allowed) { this.selectedTopics.delete(id); blocked += 1 }
      const on = this.selectedTopics.has(id)
      chip.disabled = !allowed
      chip.classList.toggle("active", on)
      chip.setAttribute("aria-pressed", String(on))
      chip.title = allowed ? "" : "You can't appoint trainers for this topic"
    })

    this.topicInputsTarget.replaceChildren(...[...this.selectedTopics].map((id) => {
      const input = document.createElement("input")
      Object.assign(input, { type: "hidden", name: "training_topic_ids[]", value: id })
      return input
    }))

    const count = this.selectedTopics.size
    this.topicCountTarget.textContent = count ? `${count} selected` : "Pick one or more"
    this.topicNoteTarget.textContent = "Greyed-out topics are ones you can record training in but can't appoint trainers for."
    this.topicNoteTarget.classList.toggle("d-none", !(this.trainerMode && blocked > 0))
    this.modeHelpTarget.textContent = this.trainerMode
      ? "They can train others in these topics. Their own training is recorded too if it's missing."
      : "Records a training for each member in each topic."
  }

  #renderMembers() {
    const totals = { actions: 0, newTrainings: 0, skipped: 0, inactiveNames: [] }
    const rows = [...this.selectedMembers.values()].map((user) => {
      const outcomes = [...this.selectedTopics].map((topicId) => this.#outcome(user, topicId))
      const acting = outcomes.filter((outcome) => outcome.acts)
      totals.actions += acting.length
      totals.newTrainings += acting.filter((outcome) => outcome.trains).length
      totals.skipped += outcomes.length - acting.length
      if (acting.length > 0 && !user.active) totals.inactiveNames.push(user.name)
      return this.#memberRow(user, outcomes)
    })

    if (rows.length === 0) {
      rows.push(this.#el("div", "text-13 text-secondary py-2", "No members added yet. Search above or paste a list."))
    }
    this.membersTarget.replaceChildren(...rows)
    this.memberCountTarget.textContent = this.selectedMembers.size
    this.element.dataset.inactiveTrainingNoticeNamesValue = JSON.stringify(totals.inactiveNames)
    return totals
  }

  #outcome(user, topicId) {
    const name = this.topicNames.get(topicId)
    const trained = (user.trained_topic_ids || []).map(String).includes(topicId)
    const trainer = (user.can_train_topic_ids || []).map(String).includes(topicId)

    if (user.banned) return { name, text: "banned", tone: "danger", acts: false }
    if (this.trainerMode) {
      if (trainer) return { name, text: "already a trainer", tone: "secondary", acts: false }
      if (trained) return { name, text: "make trainer", tone: "primary", acts: true }
      return { name, text: "train and make trainer", tone: "primary", acts: true, trains: true }
    }
    if (trained) return { name, text: "already trained", tone: "secondary", acts: false }
    return { name, text: "train", tone: "success", acts: true, trains: true }
  }

  #memberRow(user, outcomes) {
    const row = this.#el("div", "trainee-row")
    const input = document.createElement("input")
    Object.assign(input, { type: "hidden", name: "trainee_ids[]", value: user.id })

    const info = this.#el("div", "trainee-info")
    const name = this.#el("div", "trainee-name", user.name)
    if (!user.active && !user.banned) name.append(" ", this.#el("span", "badge text-bg-warning-subtle", "Inactive"))
    info.append(name, this.#el("div", "trainee-meta", user.username ? `@${user.username}` : (user.email || "")))

    const statuses = this.#el("div", "trainee-outcomes")
    if (outcomes.length === 0) statuses.append(this.#el("span", "text-11 text-secondary", "Pick a topic"))
    outcomes.forEach((outcome) => {
      statuses.append(this.#el("span", `badge text-bg-${outcome.tone}-subtle fw-normal`, `${outcome.name} · ${outcome.text}`))
    })

    const remove = this.#el("button", "trainee-remove")
    remove.type = "button"
    remove.innerHTML = "&times;"
    remove.setAttribute("aria-label", `Remove ${user.name}`)
    remove.addEventListener("click", () => { this.selectedMembers.delete(String(user.id)); this.#render() })

    const avatar = this.#el("div", "trainee-avatar", (user.name || "?").slice(0, 1).toUpperCase())
    row.append(input, avatar, info, statuses, remove)
    return row
  }

  #renderSummary({ actions, newTrainings, skipped, inactiveNames }) {
    const topics = this.selectedTopics.size
    const members = this.selectedMembers.size
    const noun = this.trainerMode ? "trainer" : "training"
    const plural = (count, word) => `${count} ${word}${count === 1 ? "" : "s"}`

    if (topics === 0) {
      this.summaryTarget.textContent = "Pick a topic to start."
    } else if (members === 0) {
      this.summaryTarget.textContent = "Add the members you trained."
    } else if (actions === 0) {
      this.summaryTarget.textContent = "Everyone selected is already done. Nothing to record."
    } else {
      this.summaryTarget.textContent =
        `${plural(members, "member")} × ${plural(topics, "topic")} → ${plural(actions, noun)}`
    }

    const notes = []
    if (this.trainerMode && newTrainings > 0) notes.push(`also records ${plural(newTrainings, "missing training")}`)
    if (skipped > 0) notes.push(`${skipped} skipped`)
    if (inactiveNames.length > 0) notes.push(`${plural(inactiveNames.length, "inactive member")}, you'll be asked about email`)
    this.detailTarget.textContent = notes.length && members && topics ? notes.join(" · ") : ""
    this.detailTarget.classList.toggle("d-none", this.detailTarget.textContent === "")

    this.submitTarget.disabled = actions === 0
    this.submitTarget.textContent = actions === 0
      ? (this.trainerMode ? "Make trainers" : "Record training")
      : (this.trainerMode ? `Make ${plural(actions, "trainer")}` : `Record ${plural(actions, "training")}`)
  }

  #hideResults() {
    this.resultsTarget.classList.add("d-none")
    this.resultsTarget.replaceChildren()
  }

  #label(user) {
    return [user.name, user.username && `@${user.username}`, user.email].filter(Boolean).join(" ")
  }

  #meta(user) {
    return [user.username && `@${user.username}`, user.email].filter(Boolean).join(" · ")
  }

  #el(tag, className, text) {
    const element = document.createElement(tag)
    element.className = className
    if (text !== undefined) element.textContent = text
    return element
  }
}

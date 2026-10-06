import { Controller } from "@hotwired/stimulus"

// Fills a datetime-local field with a date some number of days or years out, at
// 5pm local time. Each button carries its own offset so the set of offered
// durations stays in the template.
//
// Member permit forms set data-quick-expire-exact-value="true" so offsets are
// exact durations from now (or the two-week button lands on max-at exactly).
//
//   <div data-controller="quick-expire">
//     <button data-action="quick-expire#set" data-quick-expire-days-param="7">1 week</button>
//     <button data-action="quick-expire#set" data-quick-expire-years-param="1">1 year</button>
//     <input type="datetime-local" data-quick-expire-target="field">
//   </div>
export default class extends Controller {
  static targets = ["field"]
  static values = {
    exact: { type: Boolean, default: false },
    maxAt: String
  }

  set({ params: { days, years } }) {
    if (this.exactValue) {
      this._setExact({ days, years })
      return
    }

    const date = new Date()

    if (years) {
      date.setFullYear(date.getFullYear() + years)
    } else {
      date.setDate(date.getDate() + days)
    }
    date.setHours(17, 0, 0, 0)

    this.fieldTarget.value = this._localDatetimeValue(date)
  }

  _setExact({ days, years }) {
    let date

    if (years) {
      date = new Date()
      date.setFullYear(date.getFullYear() + years)
    } else if (Number(days) === 14 && this.maxAtValue) {
      date = this._parseLocalDatetime(this.maxAtValue)
    } else {
      date = new Date(Date.now() + Number(days) * 86_400_000)
    }

    if (this.maxAtValue) {
      const max = this._parseLocalDatetime(this.maxAtValue)
      if (date > max) date = max
    }

    this.fieldTarget.value = this._localDatetimeValue(date)
  }

  _parseLocalDatetime(value) {
    const [datePart, timePart = "00:00"] = value.split("T")
    const [year, month, day] = datePart.split("-").map(Number)
    const [hours, minutes] = timePart.split(":").map(Number)

    return new Date(year, month - 1, day, hours, minutes, 0, 0)
  }

  // datetime-local wants the wall-clock time, so toISOString is wrong here — it
  // would shift the value by the UTC offset.
  _localDatetimeValue(date) {
    const pad = (n) => String(n).padStart(2, "0")

    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
           `T${pad(date.getHours())}:${pad(date.getMinutes())}`
  }
}

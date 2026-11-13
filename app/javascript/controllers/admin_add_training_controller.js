import { Controller } from "@hotwired/stimulus"

// Profile "Add training" is one menu and a separate form per topic. The trainer select
// sits outside those forms, so copy the admin's choice into the form that is submitting.
export default class extends Controller {
  static targets = ["trainer"]

  stamp(event) {
    const field = event.target.querySelector("input[name='trainer_id']")
    if (!field || !this.hasTrainerTarget) return

    field.value = this.trainerTarget.value
  }
}

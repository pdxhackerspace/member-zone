import { Controller } from "@hotwired/stimulus"

// The catalog's Contact button fills one shared message dialog and points the
// form at that topic, so a member can write without opening the topic page.
//
//   <div data-controller="training-contact">
//     <button type="button" data-action="training-contact#open"
//             data-contact-url="..." data-contact-topic="..." data-contact-detail="...">
//     <form data-training-contact-target="form">
export default class extends Controller {
  static targets = ["form", "title", "detail"]

  open(event) {
    const button = event.currentTarget
    this.formTarget.reset()
    this.formTarget.action = button.dataset.contactUrl
    this.titleTarget.textContent = button.dataset.contactTopic
    this.detailTarget.textContent = button.dataset.contactDetail
  }
}

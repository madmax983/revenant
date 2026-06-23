/**
 * Jest mock for the lightning/platformShowToastEvent module so unit tests can
 * import ShowToastEvent without the real Lightning runtime. Mirrors the standard
 * sfdx-lwc-jest scaffold mock.
 */
export const ShowToastEvent = class ShowToastEvent extends CustomEvent {
  constructor(config) {
    super("lightning__showtoast", {
      composed: true,
      cancelable: true,
      bubbles: true,
      detail: config,
    });
  }
};

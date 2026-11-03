// Tests this emulator does not pass yet, by test name. Strict: a listed test that starts
// passing fails the run until its entry is removed.

export const KNOWN_FAILURES = {
  'createLoadJob accepts a gs:// source': 'configuration.load.sourceUris is refused',
};

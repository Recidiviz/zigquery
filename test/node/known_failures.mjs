// Tests this emulator does not pass yet, by test name. Strict: a listed test that starts
// passing fails the run until its entry is removed.

const SOURCE_URIS = 'configuration.load.sourceUris is refused';

export const KNOWN_FAILURES = {
  'createLoadJob loads a gs:// CSV object': SOURCE_URIS,
  'a gs:// wildcard loads every match, skipping each file header': SOURCE_URIS,
  'a gs:// load reads NEWLINE_DELIMITED_JSON': SOURCE_URIS,
  'a missing gs:// object fails the load job as not found': SOURCE_URIS,
  'a gs:// wildcard that matches nothing fails the load job as not found': SOURCE_URIS,
};

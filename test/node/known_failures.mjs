// Tests this emulator does not pass yet, by test name. Strict: a listed test that starts
// passing fails the run until its entry is removed.

const TABLEDATA_LIST = 'tabledata.list is not routed';

export const KNOWN_FAILURES = {
  'createLoadJob accepts a gs:// source': 'configuration.load.sourceUris is refused',

  'getRows returns every row of a table': TABLEDATA_LIST,
  'getRows pages with maxResults and pageToken': TABLEDATA_LIST,
  'getRows returns only selectedFields': TABLEDATA_LIST,
  'getRows starts at startIndex': TABLEDATA_LIST,
  'getRows on a missing table is a 404': TABLEDATA_LIST,

  'a resumable upload session URI names the host the client used':
    'the session URI names the address the server binds',
};

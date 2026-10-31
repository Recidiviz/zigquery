// Tests this emulator does not pass yet, by test name. Strict: a listed test that starts
// passing fails the run until its entry is removed.

const CLIENT_JOB_IDS = 'jobs.insert replaces the jobReference.jobId the client sent';
const TABLEDATA_LIST = 'tabledata.list is not routed';

export const KNOWN_FAILURES = {
  'createQueryJob results are readable through the returned job': CLIENT_JOB_IDS,
  'createQueryJob reports the rows a DML statement changed': CLIENT_JOB_IDS,
  'jobs.insert keeps the jobId the client chose': CLIENT_JOB_IDS,
  'jobs.insert rejects a jobId already in use': CLIENT_JOB_IDS,

  'createLoadJob accepts a gs:// source': 'configuration.load.sourceUris is refused',

  'getRows returns every row of a table': TABLEDATA_LIST,
  'getRows pages with maxResults and pageToken': TABLEDATA_LIST,
  'getRows returns only selectedFields': TABLEDATA_LIST,
  'getRows starts at startIndex': TABLEDATA_LIST,
  'getRows on a missing table is a 404': TABLEDATA_LIST,

  'a resumable upload session URI names the host the client used':
    'the session URI names the address the server binds',
};

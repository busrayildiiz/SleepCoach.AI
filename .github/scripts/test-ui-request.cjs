const {test} = require('node:test');
const assert = require('node:assert/strict');
const {validate} = require('./check-ui-request.js');
const repository = 'owner/repo';
const sha = 'a'.repeat(40);
function fixture() {
  return {state: 'open', draft: true, head: {sha, repo: {full_name: repository}},
    base: {sha: 'b'.repeat(40), repo: {full_name: repository}}};
}
test('exact current draft head is accepted', () => {
  assert.deepEqual(validate(fixture(), repository, sha, sha), {head: sha, base: 'b'.repeat(40)});
});
test('reject stale head, changed workflow ref and malformed SHA', () => {
  for (const [expected, workflow] of [[sha, 'c'.repeat(40)], ['c'.repeat(40), sha], ['abc123', sha]]) {
    assert.throws(() => validate(fixture(), repository, expected, workflow));
  }
});
test('reject closed/ready/fork/deleted head on initial and final checks', () => {
  for (const change of [p => p.state = 'closed', p => p.draft = false,
    p => p.head.repo.full_name = 'fork/repo', p => p.head.repo = null,
    p => p.base.repo.full_name = 'other/repo', p => p.head.sha = 'c'.repeat(40)]) {
    const pr = fixture(); change(pr);
    assert.throws(() => validate(pr, repository, sha, sha));
  }
});

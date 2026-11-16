// Validate both before dispatching expensive tests and after they finish.
function validate(pr, repository, expected, workflowSha) {
  if (!/^[0-9a-f]{40}$/.test(expected)) throw new Error('A complete lowercase PR-head SHA is required');
  if (pr.state !== 'open' || pr.draft !== true) throw new Error('Checkpoint requires an open draft PR');
  if (pr.head.repo?.full_name !== repository || pr.base.repo?.full_name !== repository) {
    throw new Error('Only same-repository PRs are supported');
  }
  if (pr.head.sha !== expected || workflowSha !== expected) {
    throw new Error('Stale or mismatched SHA: select the PR head branch and current exact head SHA');
  }
  return { head: pr.head.sha, base: pr.base.sha };
}

async function run({github, context, core}) {
  const number = process.env.PR_NUMBER;
  if (!/^[1-9][0-9]*$/.test(number)) throw new Error('Invalid PR number');
  const {data: pr} = await github.rest.pulls.get({...context.repo, pull_number: Number(number)});
  const result = validate(pr, `${context.repo.owner}/${context.repo.repo}`,
    process.env.EXPECTED_SHA, context.sha);
  core.setOutput('head', result.head);
  core.setOutput('base', result.base);
  await core.summary.addHeading(`UI checkpoint: PR #${number}`)
    .addRaw(`Tested revision: ${result.head}\n\nThis optional checkpoint never approves merge validation.\n`)
    .write();
}
module.exports = {validate, run};

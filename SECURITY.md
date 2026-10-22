# Security policy

## What to report

JobSweep keeps everything personal out of the repository: your geography, your
employer list and your output folder live in a private, gitignored profile
(`JobSweep.local.psd1`). Report anything that could defeat that, for example:

- a code path that writes, logs or sends a local file path or profile contents
  somewhere it shouldn't;
- anything that could expose credentials, tokens or other secrets;
- a way to get a profile file to run code (profiles are meant to be data only);
- a vulnerability in a GitHub Action the workflows use.

## How to report

Use **Report a vulnerability** on this repository's **Security** tab, which
opens a private advisory only the maintainer can see. Please don't open a public
issue for a security problem.

Include what you found, how to reproduce it, and which version you tested
(`$JobSweepVersion` in `Invoke-JobSweep.ps1`, or the release tag).

## What to expect

JobSweep has one maintainer, so responses are best effort. You'll get an
acknowledgement when the report is read, and the fix will be credited in the
release notes unless you'd rather it wasn't.

Fixes go into the latest release only.

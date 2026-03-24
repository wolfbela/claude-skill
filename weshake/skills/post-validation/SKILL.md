---
name: post-validation
description: >
  When I receive a PR or multiple PRs I need to générate multiple things for following the wanted process and improving the best-practices.
---

When you receive PRs number you should do 2 steps:

## Step 1: test in dev environnement:

You should find the test file in `tests/` and make a temporary copy of the file and change the base url in it two: `https://platform-api-nprd.weshake.io/api/v1`
You can launch on agent doing the test per PR to go faster.

The goal is to check everything in the dev environnement to see if the PR did well

Two possible ending:
**It's working**: go to step 2
**It's not working**: right a reaport on this and use /ticket skill to create a ticket on fixing it.

> If the test are not working, **before looking at the code to create the ticket** look at the pipeline of the github if it did broke (the pipeline) and explain why in the report but no need to create a ticket

## Step 2: Create documents to send and for self-improvement

I need 3 agents in parallèle resolving the PRs listed in $ARGUMENTS:

- 1 with the skill /qa-report
- 1 with the skill /front-doc
- 1 to feed the best-practices files.
  > The goal is to check if **yhnlvy** put a fix to the PR and feed the best-practices documents
  > with what the fix could teach. You have to feed it using the format in `./assets/best-practice_template.md`
  >
  > **IMPORTANT — Two copies to update:**
  > The best-practices file exists in two locations and BOTH must be kept in sync:
  >
  > 1. `../executing-plans/references/best-practices.md` (used by executing-plans and subagent-driven-development)
  > 2. `../test-driven-development/references/best-practices.md` (used by test-driven-development)
  >
  > When adding a new best practice, append it to BOTH files with the same content.

**MANDATORY**: Ask me for rights to right to write where they need too write and read if needed

## Rules:

- All the documents should be **in english**

---
name: coderabbit-review
description: After the PR is created, coderabbit make review from the PR. The skill need to be called on the next command after the creation of the PR to apply the review of coderabbit if needed
user-invocable: true
allowed-tools: Read, Grep, Glob, Agent, Bash, Write
argument-hint: <numéros de PR séparés par des virgules. Ex: 934,920,915>
---

You have to take a good care of coderabbit review on the code.

The goal is to **check coderabbit reviews** on the PR made **after the last commit on the PR of the actual branch** and
apply those **if they are relevant**. After this you have to pass the test suite again and after everything is all right
you are able to commit **without mentioning claude** and push.

So the flow is:

1. check the reviews of code rabbit after the commit on the PR of the actual branch
2. fix those relevant
3. pass the test suit
4. commit without mentionning claude
5. push

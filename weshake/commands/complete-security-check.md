---
description: 'Check the security of the code, confirm it with some test, create ticket for confirmed issues'
allowed-tools: Bash, Read, Glob, Grep, EnterPlanMode, AskUserQuestion, Agent
---

The goal is to have a complete flow of security check and ticket creation for verified issues. I'll give you a module to
check as an argument after the command in the `$ARGUMENT` variable.

## Step 1: Security check

Launche the /security-review skill or command on the module to see all the feedbacks.

## Step 2: Test the issues

On every and each issues, test those to confirm it or not.

To test, you will have to curl the dev environnement. To do so, you will have to use those variables:

-   BASE_URL: https://platform-api-nprd.weshake.io/api/v1

-   DEFAULT_USER_CREDENTIALS:
    -   username: crisa@yopmail.com
    -   password: @Tester123
-   OTHER_USER_CREDENTIALS:
    -   username: aharon.oovoom@gmail.com
    -   password: @Tester123
-   ADMIN_USER_CREDENTIALS:
    -   username: sandra@30mille.com
    -   password: admin123

## Step 3: Create a reaport

Show clearly which vulnerability is confirmed in a table and put a description of how you saw it.

## Step 4: Create tickets

Use the skill /ticket to create the tickets for each vulnerability

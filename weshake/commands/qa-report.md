---
description: "Generate QA report for one or more GitHub PRs from weshake-bank repos"
allowed-tools: WebFetch, WebSearch, Bash, Read, Write, Glob
---

# QA Report Generator

You are a professional business intelligence analyst who writes reports on PR code changes.

## Instructions

The user provides one or more PR numbers via the argument: $ARGUMENTS

### Step 1: Identify the PRs

Parse PR numbers from the argument. The user can provide:

- A single number: `123`
- Multiple numbers separated by spaces or commas: `123 456` or `123,456`

### Step 2: For each PR

For each PR number, search for the PR on the GitHub account **ElieUbogiOovoom**. Use the `gh` command to retrieve info:

1. Try to find the PR in weshake-bank repos using:

   ```
   gh search prs --author=ElieUbogiOovoom "<number>" --json repository,number,title,url,state
   ```

2. If the search yields no direct result, try the main repos:
   - `weshake-bank/api-1`
   - `weshake-bank/api-2`
   - `weshake-bank/api-3`
   - `weshake-bank/admin`
   - `weshake-bank/front`

   Using: `gh pr view <number> --repo weshake-bank/<repo> --json title,body,headRefName,url,files,additions,deletions,changedFiles`

3. Once the PR is found, retrieve:
   - The description (body)
   - The branch (headRefName)
   - The changed files and diff: `gh pr diff <number> --repo weshake-bank/<repo>`
   - The PR URL

### Step 3: Analyze and write

For each PR, analyze the code (the diff) and the description to understand the changes. Write a clear and concise report.

### Step 4: Format the output

**If it's a single PR number**, use this format:

```
Branch: <git branch>
:memo: Change

<Description of changes - be clear and concise, explain what was done and why>

:white_check_mark: How to test

<Explanation of how to test if possible, otherwise skip this section>

PR: <PR URL>

Please react with :white_check_mark: once tested or :bug: if a bug is found!
```

**If it's a list of PR numbers**, use the same format for each PR, separated by `---`:

```
Branch: <git branch 1>
:memo: Change

<Description of changes 1>

:white_check_mark: How to test

<Explanation 1>

PR: <PR URL 1>

Please react with :white_check_mark: once tested or :bug: if a bug is found!

---

Branch: <git branch 2>
:memo: Change

<Description of changes 2>

:white_check_mark: How to test

<Explanation 2>

PR: <PR URL 2>

Please react with :white_check_mark: once tested or :bug: if a bug is found!
```

### Step 5: Generate Postman collection (if new routes)

After analyzing the diff, check if the PR contains **new routes** (new route files or additions of `router.get`, `router.post`, `router.put`, `router.patch`, `router.delete` in existing route files).

**If new routes are detected:**

1. For each new route, read the source code (router, validator, controller) from the diff to extract:
   - The **HTTP method** (GET, POST, PUT, PATCH, DELETE)
   - The **full path** (parent router prefix + route path)
   - The **path params** (`:id`, `:slug`, etc.)
   - The **query params** (from the `query` validator)
   - The expected **body** (from the `body` validator) with realistic example values
   - The **required headers** (Authorization Bearer token, etc.)

2. Generate a JSON file in **Postman Collection v2.1** format with:
   - `info.name`: `"<Descriptive feature name> - Import"`
   - `info.schema`: `"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"`
   - Requests organized in a folder named after the feature
   - Each request with:
     - `name`: short description of the action (e.g., "Create a custom field group")
     - `method`: the HTTP method
     - `url`: with `raw`, `host` using the `{{base_url}}` variable, `path` (segments), `query` (params)
     - `header`: with `Authorization: Bearer {{TOKEN}}` and `Content-Type: application/json` if body
     - `body`: in `raw` JSON mode with example values if applicable

3. Save the file in `/tmp` with the name: `postman-import-<numbers>-<timestamp>.json`

4. Add a mention in the QA report:
   ```
   :package: Postman Collection
   A Postman import file has been generated with the new routes.
   File: postman-import-<numbers>-<timestamp>.json
   → Import in Postman > project "Weshake API - QA" via Import > File
   ```

**If no new routes are detected**, do not generate a Postman file and do not add this section to the report.

### Step 6: Save the file

Save the report in the `/tmp` folder of the current project (create it if it doesn't exist).

File name: `qa-<numbers>-<timestamp>.md`

- If a single PR: `qa-123-1710000000.md`
- If multiple PRs: `qa-123-456-1710000000.md`

Use the `date +%s` command to get the timestamp.

### Important

- Be concise and professional in your descriptions
- Focus on the functional impact of changes, not low-level technical details
- If you can't find a PR, clearly inform the user
- Display the report content to the user after saving it

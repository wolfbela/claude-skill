---
name: new-project
description: "Create a branch from develop and enter plan mode to analyze the codebase"
user-invocable: true
allowed-tools: Bash, Read, Glob, Grep, EnterPlanMode, AskUserQuestion, Agent
argument-hint: <description or ticket link>
---

# Start Feature/Fix Branch

## Instructions

The user provides a description of what they want to do via the argument: $ARGUMENTS

### Step 0: Conditional

**If the $ARGUMENTS is a link of a ticket** you should fetch it by running the script:

```bash
bash /home/jycxed/.claude-skills/weshake/skills/new-project/scripts/fetch_ticket.sh "<ticket-url>"
```

Look at the `name` and `description_html` fields in the JSON response for the informations.

> **After the fetch** change the name of the session by the name of the ticket

### Step 1: Create the branch

1. First, make sure you are on the `develop` branch and that it is up to date:

   ```
   git checkout develop && git pull origin develop
   ```

2. Infer an appropriate branch name from the user's description. Use the format:
   - `feat/<short-description>` for a new feature
   - `fix/<short-description>` for a bugfix
   - `refactor/<short-description>` for refactoring
   - `chore/<short-description>` for maintenance

   branch name must be in kebab-case, concise and descriptive.

3. Create the branch:

   ```
   git checkout -b <branch-name>
   ```

4. Confirm the created branch name to the user.

### Step 2: Enter plan mode

Immediately start brainstorming with the `/brainstorming` skill to:

1. **Fully understand the requirement**:
   > It has to go through all the dependence tree and ask relentlessly until having a complete understanding of the
   > context needed.
2. **Analyze the codebase** in relation to the given description
3. **Identify the relevant files** (routes, controllers, services, models, validators, etc.)
4. **Understand existing patterns** to stay consistent with the current code
5. **Ask questions** to the user about ambiguous points or implementation choices

### Step 3: Test the code **MANDATORY**

You must run the /test-api skill to test.

### Step 4: Push the code

You must commit the code in 1 or more commits **without mentioning CLAUDE**. Then push it and use the /pr-creation skill
to create the associated PR.

- **Never add test files in the commit but never delete them**.
- **If there is a link sent in argument** put it in the PR description.

### Important

- NEVER start coding before having a plan validated by the user
- Ask all necessary questions to fully understand the requirement
- Analyze the project's patterns and conventions before proposing a plan
- The plan must be detailed: files to modify/create, precise changes, and implementation order
- When creating commits for the PR **NEVER MENTION CLAUDE**

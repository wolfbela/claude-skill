---
name: ticket
description: Creates detailed technical tickets by analyzing the codebase. Use bullet points in the objective to create multiple tickets, or plain text for a single ticket. Trigger it when we mention the need of creating a ticket about a subject.
user-invocable: true
allowed-tools: Read, Grep, Glob, Agent, Bash, Write
argument-hint: <ticket(s) objective>
---

# Technical Ticket Creator

## Input

`$ARGUMENTS` contains the objective of the ticket(s) to create.

- If the objective contains **bullet points** (lines starting with `-`, `*`, or numbers), create **one ticket per bullet point**.
- If the objective is plain text without bullet points, create **a single ticket**.

## Process

1. **Objective analysis**: Carefully read `$ARGUMENTS` to identify the ticket(s) to create.
2. **Codebase exploration (backend)**: For each ticket, explore the codebase to:
   - Identify the relevant existing files (routes, controllers, services, models, validators, etc.)
   - Understand the project's patterns and conventions
   - Determine the endpoints to create/modify if applicable
   - Identify dependencies and impacts
3. **Front-end exploration — MANDATORY**: For each ticket, call the `front-browsing-file` agent (via the `Agent` tool, `subagent_type: "front-browsing-file"`). The agent works inside `/Users/jycxed/Documents/nekudatech/weshake/front`. Give it the ticket objective and ask it to determine:
   - Which pages/screens are involved.
   - Whether the feature can be tested from the interface (OUI/NON) and, if yes, the exact click-by-click steps; if no, why and which alternative to use (Postman, script, indirect trigger).
   You MUST wait for the agent's report before writing the `How to test` section — do not guess front behavior from backend code alone.
4. **Writing**: Write each ticket according to the template below. The `How to test` section must reflect the agent's findings (OUI ⇒ interface steps; NON ⇒ backend test with Postman + body + URL, with a short explanation of why the interface path isn't available).

## Output Template

For each ticket, produce exactly the format showed in `./assets/output_template.md`.

## Saving

Push each ticket to the task manager by calling the script `./scripts/create_ticket.sh` with two arguments:

1. **name**: The ticket title (plain string, e.g. `"[Auth] Add password reset endpoint"`)
2. **description**: The ticket description in HTML (plain string, e.g. `"<p>Description here</p>"`)

Example:

```bash
bash ./scripts/create_ticket.sh "[Auth] Add password reset endpoint" "<p>Implement the POST /auth/reset-password endpoint...</p>"
```

The script handles authentication (login + cookie extraction) automatically before creating the ticket.

## Rule

- **Always explore the codebase** (backend AND front, via `front-browsing-file`) before writing a ticket. Do not guess file paths or structures.
- Titles must be concise (max 15 words after the theme in brackets).
- The theme in brackets must reflect the functional domain (e.g., `[Auth]`, `[Payment]`, `[Client]`, `[Admin]`, etc.).
- The description must be detailed enough for a developer to start working without asking questions.
- Endpoint inputs/outputs must be realistic and consistent with the project's existing conventions.
- Separate each ticket with a horizontal rule `---` when there are multiple tickets.

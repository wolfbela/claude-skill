---
name: holon-feature
description: When I want to create a feature for the project-holon
---

The project is a one repo with the front and the back in the same directory.

The whole goal of the project is explane in the README.MD file. So when we need to implement the feature you should:

## Step 0: fetch the issue

I will give you an issue ID and you should fetch the issue to look at it and start the process for implementation

## Step 1: Create the branch

Create a branch from `master` for the feature with a adapted name.

## Step 2: Look at the README file

Look at the adapted section in the `README.md` file for the feature.

- **the feature is back**: You can look at how to implement the back section
- **the feature is front**: If it is described in the README look at what to do and in **every case** look at the styling part.

## Step 3: go to brainstorm

Go to plane mode to ask me all the question needed and explore the code to keep a logique all threw the process.

## Step 4: Test the code

Create tests of the code to cover **EVERYTHING**. Use the right skill depending on the feature type:

- **the feature is back**: Use the skill `jest-api-test` to generate exhaustive Jest API tests.
- **the feature is front**: Use the skill `playwright-e2e-test` to generate exhaustive Playwright E2E tests covering all user flows, dark mode, responsive design, and accessibility.
- **the feature is both**: Use both skills — `jest-api-test` for the API layer and `playwright-e2e-test` for the frontend layer.

## Step 5: Make the commits

I need to create one or multiple commits for the created feature with a good separation of need.

**MANDATORY**: Never mention CLAUDE in the commits

## Step 6: Create the PR

We need to create the PR associated with the code. It should have a description, be linked to the created issue and how it has been tested.

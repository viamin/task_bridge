# Contributing

Thanks for helping improve TaskBridge.

## Before You Start

- Open an issue for larger changes so the work can be discussed before implementation.
- Keep pull requests focused on a single change whenever possible.
- Include tests for behavior changes and bug fixes.

## Setup

Install the project dependencies before making changes:

```sh
bundle install
yarn install
```

If you are changing JavaScript or styles, rebuild the assets locally as needed with the existing project scripts.

## Quality Checks

Run the main local checks before opening a pull request:

```sh
bundle exec rubocop
bundle exec rspec
```

If a change affects a specific area, run the narrowest relevant spec file first, then finish with the full suite.

## Pull Requests

- Describe what changed and why.
- Link the related issue when there is one.
- Call out any follow-up work or manual verification that is still needed.
- Include screenshots or logs when they help explain the change.

## Reporting Problems

Use an issue to report bugs or request features. Include:

- What you expected to happen
- What actually happened
- The steps to reproduce
- Any relevant environment details

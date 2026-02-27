Review the current app flow and feature set in this project against the OpenAI Apps SDK UX principles stored in memory at `ux-principles.md`.

Evaluate against all five rules:

1. **Extract, Don't Port** — Are we exposing only the core user job (record → edit → export)? Any extraneous controls or settings that should be removed?
2. **Conversational Entry** — N/A for macOS native, but check: does the UI support first-run discoverability and teach the workflow?
3. **Design for the Environment** — Is UI used only for clarification/input/structured results? Any decorative components that add no functional value?
4. **Optimize for Conversation, Not Navigation** — Are actions single-step? Are status messages concise and ephemeral? No navigation trees?
5. **Embrace the Ecosystem** — Does the app stay focused on its core job without duplicating OS-level functionality?

Also check the "Avoid" list:
- Long-form static content → should be ephemeral
- Complex multi-step workflows
- Upsells, ads, irrelevant messaging
- Sensitive info exposed unnecessarily
- Duplication of system functions

For each issue found, show where in the code it manifests and suggest the minimal fix. Summarize what's already compliant.

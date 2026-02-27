Review the current SwiftUI/AppKit UI code in this project against the OpenAI Apps SDK UI guidelines stored in memory at `ui-guidelines.md`.

Check for:
1. **Color usage** — brand accent (red) only on primary CTAs; all other elements use system semantic colors (`Color.primary`, `Color.secondary`, `Color.accentColor`)
2. **Typography** — system fonts only, limited size variation, bold/italic reserved for content
3. **Icons** — monochromatic outlined SF Symbols only (no filled icons except in content areas)
4. **Materials** — `.ultraThinMaterial` for glass panels; `.environment(\.colorScheme, .dark)` applied correctly
5. **Layout** — consistent padding, visual hierarchy (headline → supporting text → CTA), no cramped text
6. **Accessibility** — sufficient contrast, layout survives text resizing
7. **Controls** — max two primary actions per card; no deep navigation or nested scrolling

For each violation found, show the file + line and suggest the compliant fix. Then summarize what's already correct.

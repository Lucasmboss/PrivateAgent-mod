---
name: Assistant voice boundary
description: Safety boundary for Android default-assistant and native voice entry points.
---

Android assistant invocations must open the normal Agent UI and use the same task executor, consent dialogs, limits, and audit trail as in-app requests. Native voice services only provide input/output and must not execute actions directly.

**Why:** The Android voice service runs outside the Flutter screen and should not become an unreviewed privileged execution path. Keeping one audited execution path preserves the existing distinction between voice intent, action approval, and verified outcome.

**How to apply:** When extending the assistant or voice integration, route recognized text into Agent mode, keep Google Speech Services/Text-to-Speech as an adapter, and preserve fallback/error reporting when Google components are unavailable.
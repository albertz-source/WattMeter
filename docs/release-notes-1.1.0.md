# WattMeter 1.1.0

## New features

- **Component temperatures**: CPU / GPU / SSD / battery / platform.
  SMC keys are discovered automatically at launch, and GPU temperature is now read correctly.
- **Adapter input voltage / current** (`VD0R × ID0R`), shown directly on the flow-diagram input node.
- **Bilingual UI** (English / 简体中文) — switch from the panel footer or the right-click menu;
  the choice is remembered.
- **Launch at login** via `SMAppService`.

## Fixes

- Main window content was clipped at the bottom.
- GPU temperature was missing and the CPU peak temperature was under-reported.
- Flow-line direction was reversed and the line width jittered with every reading
  (the width is now fixed, and the dots flow from source to load).

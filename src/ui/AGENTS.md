# UI and editor

- Follow SPEC.html's UI and text-preservation contracts.
- Keep shaped/rendered text separate from authoritative source bytes.
- Use stable element identities across immediate UI, focus, actions, and accessibility.
- Keep background computation off the UI path; bound per-frame work and sleep when idle.
- Test IME composition, grapheme navigation, selection, bidi, DPI, and accessible text ranges before claiming editor support.

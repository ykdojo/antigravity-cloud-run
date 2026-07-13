---
name: half-clone
description: >-
  Use this skill when the user asks to half-clone the conversation, shrink or
  free up context, or continue in a smaller conversation. It clones the later
  half of the current conversation into a new one the user can resume.
---

# Half-clone the conversation

Clones the later half of the most recent conversation (usually this one) into
a new conversation, cutting at the middle user turn. The original is untouched;
the clone starts with half the context.

## Steps

1. Run the bundled script:

```bash
bash ~/.gemini/config/skills/half-clone/scripts/half-clone.sh
```

2. It prints the new conversation id and how many steps were kept. Live
   conversations are safe to clone (the copy is a consistent snapshot).

3. Tell the user: open the clone with `/resume` - it's the newest entry,
   titled after its first kept message. This current conversation stays as-is,
   so they should switch to the clone to benefit from the smaller context.

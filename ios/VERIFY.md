# Hand checks for this build

Stone's Verify This Build screen (Settings) lists every line below that
starts with "- ", for a Pass or Fail on the phone, and records the results as
an `audited` tag on the build's check-in. It posts a one-line summary to the
forum thread named on the Report line (the full hash of its first post).

For whoever changes the app: when a change can only be confirmed on the
phone, add one line here saying what to look at, with the check-in. Remove
lines once a run has passed them.

Report: e320232451a750cd3fb527cfb0930f01bd85b50622ca21a97751c8aa3f86f49e

- A repo's title bar shows its name in full, with three buttons on each side. (72e3f660ea)
- No pop-up appears after Sync All, or after the Sync button inside a repo. (7ddd7489a6)
- Tapping a repo's sync icon on the home list shows that sync's results, and doesn't open the repo. (7ddd7489a6)
- A repo's sync icon goes blank about 15 minutes after its last sync. (7ddd7489a6)
- After opening a repo and coming back, every repo still gets its timed sync, and the results say what started each sync. (36b81d3295)
- The timeline fits the screen: long branch names wrap instead of running off the edge. (344c519975)
- In a conversation, the reply box stays above the keyboard, including after "Reply to this post". (f805e3d869)
- Record results on this screen adds an audited tag to the build's check-in and posts a summary on the Report thread.

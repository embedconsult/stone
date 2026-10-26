# Hand checks for this build

Stone's Verify This Build screen (Settings) lists every line below that
starts with "- ", for a Pass or Fail on the phone, and records the results as
an `audited` tag on the build's check-in. It posts a one-line summary to the
forum thread named on the Report line (the full hash of its first post).

For whoever changes the app: when a change can only be confirmed on the
phone, add one line here with the check-in. Say where to go and what to tap,
starting from the home screen, then what should be seen. Remove lines once a
run has passed them (the audited tags on the check-ins record which).

Report: e320232451a750cd3fb527cfb0930f01bd85b50622ca21a97751c8aa3f86f49e

- Sync icon goes blank: in Settings, turn Automatic Sync off. On the home screen, tap Sync All (the circling arrows, top right); each repo gets a green check beside its name. Leave the app for 15 minutes, then come back to the home screen: the checks are gone. Turn Automatic Sync back on afterwards. (7ddd7489a6)
- Timeline fits: on the home screen, tap Stone to open it, then tap Timeline in its menu. Every entry fits the screen's width; long names such as agent/20260921T025205Z-... wrap onto a second line; nothing needs scrolling sideways. (344c519975)
- Reply box above the keyboard: on the home screen, tap the speech bubbles (top left) and open any conversation. Tap the reply box at the bottom: it sits just above the keyboard. Then close the keyboard, long-press any bubble, and choose Reply to this post: the box is again just above the keyboard. (f805e3d869)
- Incomplete, not fail: on this screen, leave at least one line Not checked, mark none Fail, and tap Record results. The summary on the Report thread says "incomplete", not "fail". (this change)
- Results survive leaving: on this screen, tap Run automatic checks and mark one line Pass. Go back to Settings, then to the home screen, open any repo, and come back to Settings → Verify This Build: the automatic results and the Pass are still there. (this change)

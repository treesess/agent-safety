# 追加到 GitHub discussion #13528 的文字

> 用法：把下面 `---` 之後的英文整段貼成該 discussion 的新留言。
> 內容只寫「發表之後新查到、而且會改變結論」的部分，不重複原貼文。

---

**Two-day follow-up: a correction to my own report, and one finding that matters more than the original bug.**

When I filed this I wrote that everything was recovered. That was wrong, and the correction makes the case stronger, not weaker.

**1. "Recovered" was only size-and-count recovery.**

The files came back with exact original sizes and byte totals — and 78+ of them had entirely zeroed content (15 completely destroyed). The zero runs are 4 KB page-aligned. This turns out to be a known Windows VSS defect: shadow copies can return NULL blocks with no error at all, same file size, nothing in the event log. It reproduces from Windows 8.1 through Windows 11 25H2 (Microsoft support case 115060812822144 was closed as a confirmed bug; a 2026-10-31 report reproduces it on 25H2). So "I have shadow copies" is not a recovery plan.

**2. Timeline correction.**

The command was issued at 19:02:16 and killed at 19:04:23 — an upper bound of 127 seconds, not "2–3 minutes". Damage was first observed at 19:05:25. The approval policy was switched to "ask" at 19:04:16 — two minutes after the destructive command was already running. By the time a human could have been asked, the folder was gone.

**3. The part that actually matters for the runtime design.**

At 19:00:11 — 125 seconds before the fatal command — a review subagent I had spawned delivered a P0 finding:

> `-Dest C:\`, `-Dest .`, `-Dest C:\Users` will all pass the guard. `uninstall.ps1`'s `-Dest` has no validation at all, and `-Purge` will delete whatever it points at.

The agent received it and **acted on it**: 59 seconds later it rewrote both scripts and added the missing guard, specifically in response to that review. That part worked.

Then it validated the new guard by running `-Dest "C:\" -Force`. The guard had a hole (the canonicalizer deliberately leaves a 3-character drive root as `C:\`, while the drive-root check was written as `^[A-Za-z]:$`, which only matches the trimmed form). The test input and the protected object were the same thing, so validation became the accident.

So this was not "the agent ignored a warning". The warning arrived, was understood, and was implemented. The failure was in **how a safety guard gets tested**.

**4. Updated asks.**

- *(unchanged, still the most valuable)* Destructive shell calls should route through a gate even in full access, and the approval card should show the **canonical** target so a human sees `C:\` immediately.
- *(new, cheapest)* Agents need an explicit norm: **a guard test must use a decoy target**. `-Dest "C:\__probe_does_not_exist__"` would have caught the identical bug with zero risk — the guard fails, and nothing real is deleted. One line in the tool description or system prompt would have prevented this incident. It costs nothing and it is checkable.
- *(new, for anyone reading this as "just enable snapshots")* Verification must check **content**, not counts: page-level zero detection, hashes, `testzip()` for archives. And copy the shadow out to a different disk **before** restoring over the live tree — otherwise the restore itself destroys the evidence you would need to answer "was the original fine?".

I have a full post-mortem (Traditional Chinese) with the millisecond timeline, the recovered source of the two scripts, and the evidence trail, plus a small scanner that detects zeroed content by page alignment. Happy to share either.

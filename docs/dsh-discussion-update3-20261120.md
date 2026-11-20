# 追加到 GitHub discussion #13528 的第三則留言（2026-11-20）

> 用法：把 `---` 之後的英文整段貼成該 discussion 的**新留言**。
> 前兩則（`#discussioncomment-19706348`、`#discussioncomment-19711922`）保持不動。
> 貼完把永久連結補到下面「正文指標」的 `Third:`。

---

**Third follow-up: the "complete recovery" check was itself only partial — and here is why I found that now.**

The earlier correction said the restore was "size-and-count recovery only." That is true, but it was too generous to the count check. This update is about what that check actually covered.

**What the check compared**

On the day of the incident, the recovery report compared the restored tree with the shadow copy directory by directory: **14 directories, 1,367 files, 483 MB**. The whole tree was **1,372 files, 1.744 GB**.

The five files at the root of the working folder — images and videos, about **1.3 GB**, roughly **72% of the bytes** — were never in the comparison loop. The report table still had a row that said, in effect, "the rest (videos, images, …) — all ✓", with a dash in the size column. That checkmark was not backed by a comparison.

The same reasoning block said to "compare hashes for a few files." The command that actually ran was `Get-ChildItem` plus `Measure-Object`: file counts and summed lengths, no `Get-FileHash`. The hash check was planned and not executed.

**Why this is a third update, not a footnote**

The first review (2026-11-18) used extraction and summarization: user messages, tool calls, the assistant's visible text, key events. That is a lossy pass. It excluded the assistant's internal reasoning and truncated tool results.

The second pass (2026-11-20) read the raw event stream in order — reasoning, complete commands, results — for the incident and recovery windows, without pre-summarizing. That is how two gaps surfaced that the summary had hidden:

1. At 19:01:10 the agent's plan for the path guard contained **two** drive-root checks: the regex, and an equality check against the drive root. Only the regex was written into the code. The planned equality check was never implemented.
2. In the recovery window, the reasoning called for hash comparisons, but the executed command only counted files and summed bytes; the comparison table then marked unmeasured files as verified.

The mechanism is the same in both places: **the intention lived in the reasoning, and the summary did not read the reasoning.** A plan-to-code gap and a plan-to-verification gap are both invisible if you only read the code and the report.

**How the error then spread**

A context file written for three helpers was headed "confirmed environment facts." It stated that the folder had been "recovered completely" with VSS and robocopy. The public write-ups were drafted from that file. So the unverified conclusion did not stay in one message: it was labeled as confirmed, handed to fresh workers, and inherited by the public documents.

**What changed**

`docs/incident-review-public.md` now records the partial coverage (14 directories / 1,367 files / 483 MB; five root media files, ~1.3 GB, unmeasured) next to the original 143/1,372/1.744/0 FAILED line, and adds an appendix on the two-pass reading method that found the gap. The root-cause section also now says the equality check against the drive root was planned and never implemented, and that the leaf-name check which would have rejected `C:\` was disabled by the test's own `-Force` flag.

**The part I did not expect**

About two and a half hours after that rule was written (a little over three hours after the incident), a delegated cleanup instruction asked a teammate to recursively delete a named scratch directory inside the protected tree, with confirmation. It was scoped and named, so it was not a violation of the rule that had just been written — but it was the same shape: recursive delete, a path inside the protected tree, execution handed to another agent, and no canonicalization by the agent that issued it. Writing a rule does not remove the shape the rule was written about.

**The lesson I would keep**

- A summary is not a substitute for one sequential read. If you are auditing an agent incident, read the reasoning in the critical window at least once. Intent lives there, and so do the checks that never made it into the code.
- "Verified" needs a scope: which files, which bytes, which method. "Counts and totals matched" is not the same as "the tree was compared."
- Anything labeled "confirmed facts" for downstream writers needs the same evidence bar as the final document. Otherwise the correction has to be made twice: once in the record, once in everything that inherited it.

I would rather publish a third correction than leave a cleaner story that is not true.

---

# 正文指標（可選）

若要把置頂正文的指標更新成三則，可把原本 First/Second 兩行改成：

> **Update 2026-11-18 — corrections in the comments.** The original "recovered … verified
> byte-for-byte" claim was size-and-count recovery only. A first follow-up corrects the
> timeline, the root cause and the VSS claim; a second reports the decoy experiment (the
> zeroing did not reproduce); a third corrects the recovery check itself — it covered only
> 14 directories / 1,367 files / 483 MB, and five root media files (~1.3 GB) were never
> compared, because the planned hash check was not run.
> First: <https://github.com/deepseek-ai/deepseek-harness/discussions/13528#discussioncomment-19706348>
> Second: <https://github.com/deepseek-ai/deepseek-harness/discussions/13528#discussioncomment-19711922>
> Third: <https://github.com/deepseek-ai/deepseek-harness/discussions/13528#discussioncomment-19767313>

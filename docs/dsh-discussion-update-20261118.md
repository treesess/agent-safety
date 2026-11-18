# 追加到 GitHub discussion #13528 的文字

> 用法：把下面 `---` 之後的英文整段貼成該 discussion 的新留言。
> 內容只寫「發表之後新查到、而且會改變結論」的部分，不重複原貼文。
>
> **狀態（2026-11-18 18:37 更新）：留言已貼、正文前向指標也已加。**
> 留言永久連結：<https://github.com/deepseek-ai/deepseek-harness/discussions/13528#discussioncomment-19706348>
> 下方「正文前向指標」一節保留作記錄與下次的範本（含佔位符的用法說明）。

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

---

# 正文前向指標（建議加在討論正文最頂端）

**為什麼要有這個**：留言保留歷史（符合「已發佈的文字不改」的原則），但新讀者會停在正文的舊結論上。
兩者的交集是：**正文一字不改，只在最頂端加一行指向留言。** 這是勘誤表的標準做法——歷史留著，
誤導被擋住。

## 英文版（貼在正文第一行）

> **Update 2026-11-18 — correction in the comments.** The claim below that everything was
> "recovered … verified byte-for-byte" turned out to be size-and-count recovery only:
> 78+ files came back with exact original sizes and entirely zeroed content (a known Windows
> VSS defect). The timeline and the root cause below are also wrong in detail.
> Full follow-up: https://github.com/deepseek-ai/deepseek-harness/discussions/13528#discussioncomment-19706348

### `_<貼上這則留言的永久連結>_` 是什麼意思

那是**佔位符**，不是要照抄的文字：

- `_…_` 是 Markdown 的斜體語法，用來讓它在畫面上看起來是「待填」的示意字。
- `<…>` 是佔位慣例，表示「這裡要換成真的東西」。
- **整段 `_<貼上這則留言的永久連結>_` 要換成一個網址。** 連底線和角括號一起刪掉。

「留言的永久連結」＝會直接跳到那則留言的 URL。**這次實際的連結是：**

```
https://github.com/deepseek-ai/deepseek-harness/discussions/13528#discussioncomment-19706348
```

最後那串 `#discussioncomment-19706348` 就是定位到單一留言的錨點。

**怎麼拿**（下次用）：在留言右上角按 `···` → `Copy link`；或直接點留言旁的發佈時間，網址列會變成帶錨點的形式，複製起來。

**實際貼在正文的樣子：**

> Full follow-up: https://github.com/deepseek-ai/deepseek-harness/discussions/13528#discussioncomment-19706348

包成連結也可以：

> Full follow-up: [the correction comment](https://github.com/deepseek-ai/deepseek-harness/discussions/13528#discussioncomment-19706348)

**如果一時拿不到連結**，就直接寫 `Full follow-up: see the correction comment below.` 也可以——讀者往下滑一小段就找得到。

## 繁中版（若正文有繁中摘要，也放同一位置）

> **2026-11-18 更正（詳見下方留言）**：本文「完整救回、與影子逐位元組一致」的結論已被推翻——
> 實際只救回檔案大小，78 個以上檔案內容為零（Windows VSS 已知缺陷）；下方時間線與根因也已修正。
> 完整更正：<https://github.com/deepseek-ai/deepseek-harness/discussions/13528#discussioncomment-19706348>

## 不要做的事

**不要回頭把正文那句改成對的。** 那會讓底下的回覆失去上下文，也毀掉「當時說了什麼」這個事實。
更正用追加的，正文只加指標。


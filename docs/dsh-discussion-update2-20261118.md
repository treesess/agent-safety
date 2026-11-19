# 追加到 GitHub discussion #13528 的第二則留言（2026-11-18 晚間）

> 用法：把 `---` 之後的英文整段貼成該 discussion 的**新留言**。
> 第一則留言（`#discussioncomment-19706348`）保持不動；這一則是「測過了，但沒有重現」的更新。
> 貼完後，把永久連結補到下面「正文指標」的佔位符。

---

**Follow-up: we tried to reproduce the zeroing, and it did not reproduce.**

Since my last comment I ran a controlled decoy experiment on the same machine. The question was simple: does deleting a file make a VSS snapshot read back zeros?

- A fresh shadow copy, an 8 MB decoy, deletion via `Remove-Item` → the snapshot returned the original bytes at t+0/60/180 s.
- Same with `cmd /c rd /s /q` (the incident's delete path) → identical.
- 128 × 8 MB (1 GB) deleted in one `rd /s /q` → 128/128 files still returned the original bytes; zero zeroed files.
- Repeated on the original build (26200.8457) and after the November update (26200.9974): same result.

So **TRIM, the delete API, and mass deletion up to 1 GB are not sufficient** to explain the zeroing. The documented VSS NULL-block behaviour is still the best available explanation — but it is not confirmed, and I should have said that more carefully the first time.

Two number corrections while I am here:

- **78 is a lower bound.** The 4 KB rule cannot fire on files smaller than 4 KB; at least ~112 files were affected (15 entirely zero).
- **The zeroed content is 8.5 MB, not 144.9 MB.** 144.9 MB is the total size of the damaged files — one 134 MB file had only a few 4 KB holes.

One operational detail: after a reboot Windows reassigns shadow device numbers (my S22/S23 became `ShadowCopy1/2`). Hard-coded `\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyNN` paths do not survive a restart; resolve the device object every time.

The lesson I would keep is narrower than "VSS is broken": **a shadow copy is a recovery mechanism, not a backup, and "restored" must be verified by content.** The test method is documented in `docs/vss-null-blocks.md`.

---

# 正文指標（可選）

若想把置頂正文的指標也更新成「兩則留言」，可把原本那行改成：

> **Update 2026-11-18 — corrections in the comments.** The original "recovered … verified
> byte-for-byte" claim was size-and-count recovery only. A first follow-up corrects the
> timeline, the root cause and the VSS claim; a second follow-up reports the decoy
> experiment: the zeroing did **not** reproduce, so the mechanism remains unconfirmed.
> First: <https://github.com/deepseek-ai/deepseek-harness/discussions/13528#discussioncomment-19706348>
> Second: <https://github.com/deepseek-ai/deepseek-harness/discussions/13528#discussioncomment-19711922>

> 註：`_<…>_` 是佔位符，貼上時整段換成網址。

import os, sys, time, fnmatch

# scan-zero-damage.py — 掃描目錄中「內容被清成零」的檔案
#
# 為什麼要有這個工具：2026-11-16 的事故後，用 VSS 還原時只核對了
# 「檔案數 / 位元組數」，大小對得上但內容其實是 0，因此損壞被漏掉。
#
# 判準（兩層）：
#   damaged  ：最大連續零段 >= 4 KB。一般文字／二進位檔不會有這種整塊零。
#   suspect  ：零段未達門檻，但整檔全零、或零位元組 >= 64 且比例 > 25%。
#              這一層是為了補「小於 4 KB 的檔案不可能出現 4 KB 零段」的盲點
#              ——2026-11-18 就是這樣漏掉 memory\projects.md（1,257 B 全零）。
#              比例不能用來取代第一層（mp4／MAT 天生含大量零會誤判），
#              只能用來「提出可疑」，由人判讀。
#
# 用法：
#   python scan-zero-damage.py "C:\000 cen"                  # 掃描並列出
#   python scan-zero-damage.py "C:\000 cen" --write          # 另存 TSV 報告
#   python scan-zero-damage.py "C:\000 cen" --min-run 8192
#   python scan-zero-damage.py "C:\000 cen" --no-suspect
#
#   # 修復後驗收：把「刻意保留的證據」排除，damaged 才是「使用路徑」的數字
#   python scan-zero-damage.py "C:\000 cen\VORON FDMs" \
#          --exclude recover --exclude "*.damaged-*"
#
# --exclude 比對「相對於 root 的路徑」與「絕對路徑」，模式用 fnmatch 語法；
# 給目錄名（例如 recover）時，其下整個子樹都會被排除。
# 被排除的目錄數與檔案數會印在摘要裡（excluded_dirs / excluded_files），不會被靜默忽略。
#
# 驗收語句建議：「使用路徑 damaged=0；suspect 每筆都有人判讀；recover\ 另列為已知證據。」
#
# 來源：C:\000 cen\5470\tools\scan-zero-damage.py 的 suspect 段
#       ＋ 本版新增的整頁零（zero_pages / page_offsets）指紋
#       ＋ 2026-11-18 新增的 --exclude（VORON FDMs 修復時的需求）。

DEFAULT_MIN_RUN = 4096
DEFAULT_PAGE = 4096


def largest_zero_run(data):
    n = len(data)
    best = 0
    best_off = -1
    i = 0
    while i < n:
        if data[i] == 0:
            j = i
            while j < n and data[j] == 0:
                j += 1
            if j - i > best:
                best = j - i
                best_off = i
            i = j
        else:
            i += 1
    return best, best_off


def page_stats(data, page=DEFAULT_PAGE):
    """整頁全零的頁數與前幾個頁偏移（頁級指紋）。"""
    n = len(data)
    pages = []
    off = 0
    while off + page <= n:
        if data[off:off + page].count(0) == page:
            pages.append(off)
        off += page
    return len(pages), pages[:6]


def _norm(s):
    return s.replace("\\", "/")


def is_excluded(relpath, abspath, patterns):
    """relpath/abspath 任一命中 pattern 就算排除；給目錄名時排除整個子樹。

    2026-11-18 修正：裸名稱（不含 / 也不含萬用字元）視為「任一層的目錄或檔名」，
    不再只匹配掃描根目錄的第一層。先前 `--exclude recover` 從 C:\\000 cen 掃時
    抓不到 VORON FDMs\\recover\\（excluded_dirs=0），會讓已排除的證據又出現在
    damaged 清單裡。
    """
    rel = _norm(relpath)
    ab = _norm(abspath)
    rel_l, ab_l = rel.lower(), ab.lower()
    for pat in patterns:
        p = _norm(pat).rstrip("/")
        pl = p.lower()
        bare = ("/" not in pl) and not any(ch in pl for ch in "*?[")
        for cand in (rel_l, ab_l):
            if fnmatch.fnmatchcase(cand, pl):
                return True
            if cand.startswith(pl + "/"):
                return True
            if bare and ("/" + pl + "/") in ("/" + cand + "/"):
                return True
    return False


def parse_args(argv):
    """容忍 flag 與位置參數任意順序（舊版只認 argv[0] 當 root）。"""
    root = None
    write = False
    no_suspect = False
    min_run = DEFAULT_MIN_RUN
    excludes = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--write":
            write = True
        elif a == "--no-suspect":
            no_suspect = True
        elif a == "--min-run":
            i += 1
            min_run = int(argv[i])
        elif a == "--exclude":
            i += 1
            excludes.append(argv[i])
        elif a.startswith("--exclude="):
            excludes.append(a.split("=", 1)[1])
        elif a.startswith("--"):
            raise SystemExit(f"unknown option: {a}")
        elif root is None:
            root = a
        else:
            raise SystemExit(f"unexpected argument: {a}")
        i += 1
    if root is None:
        root = r"C:\000 cen"
    return root, write, no_suspect, min_run, excludes


def main(argv):
    root, write, no_suspect, min_run, excludes = parse_args(argv)

    rows = []
    suspects = []
    scanned = 0
    excluded_dirs = 0
    excluded_files = 0
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        # 目錄層就先剪枝，避免走進正在排除的大樹
        if excludes:
            keep = []
            for d in dirnames:
                rd = os.path.join(rel_dir, d) if rel_dir != "." else d
                if is_excluded(rd, os.path.join(dirpath, d), excludes):
                    excluded_dirs += 1
                else:
                    keep.append(d)
            dirnames[:] = keep
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            rel = os.path.join(rel_dir, fn) if rel_dir != "." else fn
            if excludes and is_excluded(rel, p, excludes):
                excluded_files += 1
                continue
            try:
                st = os.stat(p)
                if st.st_size == 0:
                    continue
                with open(p, "rb") as f:
                    data = f.read()
            except Exception:
                continue
            scanned += 1
            zero_total = data.count(0)
            if zero_total == 0:
                continue
            run, off = largest_zero_run(data)
            if run >= min_run:
                npages, poffs = page_stats(data)
                rows.append({
                    "max_run": run,
                    "run_off": off,
                    "size": len(data),
                    "pct": round(100.0 * zero_total / len(data), 1),
                    "pages": npages,
                    "poffs": ",".join(str(x) for x in poffs),
                    "path": p,
                })
            elif zero_total == len(data):
                suspects.append({"max_run": run, "size": len(data), "pct": 100.0, "path": p})
            elif zero_total > len(data) * 0.25 and zero_total >= 64:
                suspects.append({
                    "max_run": run,
                    "size": len(data),
                    "pct": round(100.0 * zero_total / len(data), 1),
                    "path": p,
                })

    rows.sort(key=lambda r: (-r["pages"], -r["max_run"], -r["size"]))
    suspects.sort(key=lambda r: (-r["pct"], -r["size"]))

    print(f"scanned={scanned} damaged={len(rows)} suspect={len(suspects)} "
          f"excluded_dirs={excluded_dirs} excluded_files={excluded_files} "
          f"(min zero run = {min_run} B)")
    if excludes:
        print(f"excluded patterns: {', '.join(excludes)}")
    elif rows or suspects:
        print("提示：若已修復且把壞檔改名保留，請加 "
              "--exclude recover --exclude \"*.damaged-*\"，"
              "這樣 damaged 才是「使用路徑」的數字。")
    for r in rows:
        print(f"{r['pages']:>4} pages  {r['max_run']:>9} B run  {r['pct']:>5.1f}% zero  "
              f"{r['size']:>9} B  {r['path']}")

    if suspects and not no_suspect:
        print(f"\nsuspect={len(suspects)}（零段未達門檻但零比例高；小檔全毀會落在這裡，需人判讀）")
        for r in suspects:
            print(f"{r['max_run']:>9} B run  {r['pct']:>5.1f}% zero  {r['size']:>9} B  {r['path']}")

    if write:
        out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".scratch",
                           f"zero-damage-{time.strftime('%Y%m%d-%H%M')}.tsv")
        out = os.path.abspath(out)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            f.write("kind\tzero_pages\tmax_zero_run\trun_offset\tsize\tpct_zero\tpage_offsets\tpath\n")
            for r in rows:
                f.write(f"damaged\t{r['pages']}\t{r['max_run']}\t{r['run_off']}\t{r['size']}\t"
                        f"{r['pct']}\t{r['poffs']}\t{r['path']}\n")
            for r in suspects:
                f.write(f"suspect\t0\t{r['max_run']}\t\t{r['size']}\t{r['pct']}\t\t{r['path']}\n")
        print(f"\nreport: {out}")


if __name__ == "__main__":
    main(sys.argv[1:])

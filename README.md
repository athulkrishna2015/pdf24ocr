# pdf24ocr

OCR any PDF from the command line using the worker API behind
[tools.pdf24.org/en/ocr-pdf](https://tools.pdf24.org/en/ocr-pdf).

No account, no key. Files live on their German servers for about an hour.
It is someone else's free web tool being driven over its own undocumented
`client.php` endpoint — expect it to break when they change the frontend.

## Use

```sh
./pdf24ocr scan.pdf                        # -> scan_ocr.pdf + scan_ocr.txt
./pdf24ocr -l deu+eng invoice.pdf          # mixed-mode OCR across scripts
./pdf24ocr -F -o pdfa -O clean.pdf scan.pdf  # force OCR, PDF/A output
./pdf24ocr -O out/ a.pdf b.pdf c.pdf       # all three at once -> out/*_ocr.{pdf,txt}
./pdf24ocr -j a.pdf b.pdf                  # merge into one PDF
./pdf24ocr -l rus -O out.pdf --text out.txt doc.pdf
```

### Parallel OCR

Several inputs are OCR'd concurrently, one job per file, each on its own
session. The server works the files inside a single job one after another, so
splitting them is where the speedup comes from:

| 4 one-page PDFs | time |
| --- | --- |
| one job, 4 files | 2m38s |
| one job per file | 16s |

Same recognized text either way (verified byte-for-byte). `-O` is the output
directory in this mode, and `--text` only applies to a single input. `-j` is the
exception: merging has to happen server-side, so it stays one sequential job.

```sh
./pdf24ocr -p 2 -O out/ *.pdf     # gentler
./pdf24ocr -p 8 -O out/ *.pdf     # push harder, if you must
```

### Please be a decent client

This drives a small German company's free, ad-funded tool, and they did not
build it to be scripted. Some things this project does not do, deliberately:

- **No cap evading.** There is no proxy rotation, no IP spreading, no attempt to
  work around rate limits. If you get throttled, the right answer is to wait.
- **Default is 4 jobs, staggered by 1s.** Not "one job per core", not 60 at
  once. Real browsing never looks like that, and the site's own UX is one
  document at a time.
- **No CAPTCHA solving, no session forgery beyond the normal cookie.** The
  session is the same one the browser gets.
- **Nothing retries indefinitely.** A throttled or failed job is reported to you
  so you can decide, not silently hammered until it works.

`test.sh` deliberately runs **sequentially**. It is a correctness suite, not a
benchmark, and there is no reason for it to burst. The one parallel case in it
uses two files.

The site documents a per-document daily limit and deletes files after an hour.
Respecting those is on you. If you need bulk OCR at scale, that is a real
product decision — say so in an issue and the honest answer is to use a
self-hosted Tesseract, not to load this harder.

### Mixed-mode OCR

`-l` takes several codes joined by `+`, which is what the site's multiselect
sends and what Tesseract treats as one multilingual pass. It genuinely helps on
pages that mix scripts — a page with Cyrillic and English headings reads correctly
under `-l rus+eng` and comes back as garbage under `-l eng` alone:

```
-rus+eng:  Привет Мир          -eng:  lpvBpet Mup
           Order 55 line 7            Order 55 line 7
```

Codes are the Tesseract ones in the page's own dropdown: `eng`, `deu`, `fra`,
`spa`, `rus`, `chi_sim`, `jpn`, `kor`, `ara`, `heb`, plus the vertical and
historical variants (`chi_tra_vert`, `frk`, `grc`). Full list is in the
`langCode` options of the tool page.

### Options

| flag | meaning |
| --- | --- |
| `-l, --lang CODES` | tesseract codes joined by `+`, default `eng` |
| `-o, --format pdf\|pdfa` | output type, default `pdf` |
| `-O, --out FILE` | output PDF, default `<input>_ocr.pdf` |
| `--text FILE` | plain text output, default `<input>_ocr.txt` |
| `-F, --force` | OCR pages that already have a text layer |
| `-d, --no-deskew` | disable deskew (on by default) |
| `-b, --background` | detect and remove a noisy background |
| `-r, --rotate` | guess and fix page orientation |
| `-c, --clean` | remove scanning artefacts |
| `-j, --join` | merge all inputs into a single PDF (one sequential job) |
| `-p, --parallel N` | max concurrent jobs, default 4 |
| `-T, --keep-tree` | keep each result beside its source; with `-O`, mirror the tree under it |
| `-R, --resume` | skip inputs whose output is already complete |
| `-n, --dry-run` | print resolved output paths, send nothing, fail on collisions |

`-O` refuses to name a file that is also one of the inputs, so a typo can't
destroy the document you were OCRing.

### Long batches

Three flags exist because OCR'ing a folder of files is a different job from
OCR'ing one document, and the failure modes are worse.

`-T --keep-tree` — without it, everything lands flat in `-O`, so two files named
`Maths.pdf` in different folders silently overwrite each other. With it and no
`-O`, each result sits beside its source. Your filenames contain spaces,
parentheses and Malayalam script; that is handled, but only worth relying on
after checking.

`-R --resume` — a finished output is its own record of completion. Both files
must exist and the PDF must be a real PDF, so a truncated file from a killed run
is redone rather than trusted. Re-run the identical command to finish the rest.

`-n --dry-run` — the one to use first. It prints the resolved output path for
every input, sends nothing, and exits 1 if two inputs would write the same file:

```sh
# check before committing to a multi-hour run
mapfile -d '' files < <(find . -iname '*.pdf' -print0)
pdf24ocr -F -l eng+mal -c -T -R -n -p 4 "${files[@]}"
```

On a 109-file textbook set this verified all 109 outputs landed beside their
sources with no collisions, before a single request went out.

## What the extra flags actually do

Measured, not assumed. The server accepts `removeBackground`, `rotatePages` and
`clean` and echoes them back as `param.*` in `getStatus`, so they are plumbed
through. What they buy you is much less clear:

| flag | observed |
| --- | --- |
| `-d` (deskew off) | clear and reproducible. A page rotated 4° reads fine with deskew on and returns nothing with it off. |
| `-b` | output PDF changes bytes, OCR quality on my noisy fixture unchanged (empty either way) |
| `-r` | a 90°-rotated page stayed landscape and read as garbage, with and without |
| `-c` | no visible difference on input that was already clean |

They cost nothing to send, so they are exposed. Just don't expect `-r` to rescue
sideways scans. Deskew them locally first:

```sh
magick in.pdf -deskew 40% out.pdf
```

Skipped: script-word bounds (`psm`), DPI hints, per-page language. None are in
the site's own parameter set, so there is nothing to send.

`PDF24_OCR_LANG` and `PDF24_OCR_OUT` set the defaults for `-l` and `-o`.

## Limits worth knowing

- 100 MB per file, per the dropzone config on the page.
- OCR is slow and the site says so. A 4-page file took ~20s, 15 pages ~43s,
  60 sequential one-page files ~71s. The script polls every 5s and gives up
  after an hour per file.
- With several inputs and no `-j`, each file gets its own job and its own
  session, capped at `-p` (default 4) and staggered by a second.
- Uploads are the heavy part. The backend holds the file for about an hour
  afterwards, so a large batch occupies server-side storage that is not yours.
- A job can complete with zero recognized words and no error. The page was
  processed; Tesseract just found nothing. Re-run if the document is legible.
- The site caps how many times one document can be OCR'd per day. Hit it and
  `getStatus` reports something other than `pending`/`done`; the script surfaces
  the server's message.
- There is no resume-after-disconnect. A dropped network stops the batch, on
  purpose: silently reconnecting and re-uploading is not a thing this does to
  someone else's free service. Re-run the command; `-R` picks up where it
  stopped. Use `tmux` or `nohup` if the batch must outlive your terminal.

## Test

`test.sh` builds rasterized fixtures (so they have no text layer to start with),
runs them through the live API and asserts on the results.

```sh
./test.sh         # 30+ cases, hits the network
QUICK=1 ./test.sh # argument handling only, no network
```

Covered: arg validation and exit codes, English/German/Cyrillic OCR, mixed-mode
`rus+eng` (including a negative control proving `eng` alone fails on the same
page), multi-page files, text layer actually embedded in the output, deskew on
vs off, inverted scans, PDF vs PDF/A, `--force` on pages that already have text,
multi-file fan-out (one job per file), `-p` concurrency cap, `--join`, image
input, env var defaults, unicode filenames, `--dry-run` (sends nothing, catches
a flat-directory collision), `--keep-tree` with same-named files, and `--resume`
skipping a complete output while redoing a truncated one.

Each fixture is rasterized, and `mk` aborts the run if any of them already has a
text layer — otherwise "OCR worked" would pass without any OCR happening.

Tesseract is not deterministic and the shared backend occasionally returns a job
with zero recognized words. `ocr()` retries up to five times when a sidecar comes
back with only page markers. A genuine regression still fails; a transient empty
result does not.

Measured: 60 pages / 1.6 MB came back in 2m36s with all 60 recognized, twelve
sequential runs of the same document all succeeded, and three concurrent
invocations on separate sessions do not interfere.

## The API

Everything happens on `https://filetools<N>.pdf24.org/client.php`, N from 0 to 49.
The session is a `pdf24FtSid` cookie held in a curl cookie jar.

1. `POST ?action=start` — register the session, answer is `{"available":true}`
2. `POST ?action=upload` — multipart `file=@...`, returns a JSON array with the
   stored file: `{"file":"upload_<id>.pdf","size":...,"name":...}`
3. `POST ?action=ocrPdf&srcPageId=ocrPdf` — JSON body, returns `{"jobId":"..."}`

   ```json
   {"files":[<upload objects>],"langCode":"eng","outputType":"pdf",
    "title":"","author":"","subject":"","keywords":"",
    "removeBackground":false,"rotatePages":false,"deskew":true,
    "clean":false,"forceOcr":false,"joinFiles":false}
   ```

4. `POST ?action=getStatus` with `jobId=` — `status` is `pending` then `done`;
   the payload also carries `out.file` and `0.text.out.file`
5. `GET ?action=getFile&jobId=...&file=...` — the result (or
   `?action=downloadJobResult&jobId=...` for the primary output)

The endpoint list and payload shape came from `/static/js/common.js` on the
tool page. Same API works for the other tools there: `mergePdf`, `convertToPdf`,
`compressPdf`, and friends.

For reference, the site's own client ships `parallelUploads: 3` and one session
per page load. Its worker list is 50 hosts (`filetools0`…`filetools49`), all
equal weight, picked at random per session — that is capacity, not permission to
open one session per file at once.

## Notes

Not affiliated with PDF24. Their terms cover the site, not this script, and
their terms almost certainly do not grant the right to script their service at
volume. If you publish this, say so plainly.
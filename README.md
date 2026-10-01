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
./pdf24ocr -j a.pdf b.pdf                  # merge inputs into one PDF
./pdf24ocr -l rus -O out.pdf --text out.txt doc.pdf
```

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
| `-j, --join` | merge all inputs into a single PDF |

`-O` refuses to name a file that is also one of the inputs, so a typo can't
destroy the document you were OCRing.

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
- OCR is slow and the site says so. A 4-page file took ~20s, 15 pages ~43s;
  the script polls every 5s and gives up after an hour.
- With several inputs and no `--join`, the server returns one zip of PDFs and no
  text sidecars. The script unzips it and pulls each file's text separately, so
  you still get `<name>_ocr.pdf` plus `<name>_ocr.txt` per input.
- A job can complete with zero recognized words and no error. The page was
  processed; Tesseract just found nothing. Re-run if the document is legible.

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
multi-file input, `--join`, image input, env var defaults, unicode filenames.

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

## Notes

Not affiliated with PDF24. Their terms cover the site, not this script — if you
publish this, say so plainly.
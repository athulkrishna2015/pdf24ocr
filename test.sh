#!/usr/bin/env bash
# Integration tests for pdf24ocr. Every case hits the live PDF24 API, so it needs network.
#   ./test.sh          all cases
#   ./test.sh quick    only the fast ones
set -uo pipefail
cd "$(dirname "$0")"

SCRIPT=./pdf24ocr
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
F=DejaVu-Sans

ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { # check <name> <needle> <file>
	if grep -qi -- "$2" "$3" 2>/dev/null; then ok "$1"; else no "$1 (missing '$2')"; fi
}
exists() {
	[[ -f $2 ]] && ok "$1" || no "$1 ($2 not created)"
}

# Tesseract is not deterministic: the same page sometimes comes back with no
# recognized text. Retry in that case — an empty sidecar means the check below
# would fail for a reason unrelated to the script.
ocr() { # ocr <base> [pdf24ocr args...]
	local base=$1
	shift
	for _ in 1 2 3 4 5; do
		# a nonzero exit must fail the case even when the output files look fine —
		# that hides real breakage
		"$SCRIPT" -O "$base.pdf" --text "$base.txt" "$@" >/dev/null 2>&1 || return 1
		# "@@@ Page 1 @@@" on its own means the page was processed but nothing was read
		if sed 's/@@@ Page [0-9]* @@@//g' "$base.txt" 2>/dev/null | grep -q '[^[:space:]]'; then
			return 0
		fi
		sleep 5
	done
	return 1
}

for c in magick pdftotext zipinfo; do
	command -v $c >/dev/null || {
		echo "needs $c" >&2
		exit 2
	}
done

# ---- fixtures: rasterized pages, so nothing has a text layer to begin with ----
echo "building fixtures..."
mk() { # mk <file> <line1> [line2]
	local f=$1 a=$2 b=${3:-} extra=${4:-}
	magick -size 1240x1754 xc:white -font $F -pointsize 84 -annotate +100+400 "$a" \
		${b:+-pointsize 56 -annotate +100+560 "$b"} $extra "$tmp/$f.jpg"
	magick -quality 88 "$tmp/$f.jpg" "$tmp/$f.pdf"
	# a fixture that already had text would pass these tests without any OCR happening
	if [[ -n $(pdftotext "$tmp/$f.pdf" - 2>/dev/null | tr -d '[:space:]') ]]; then
		echo "fixture $f already has a text layer — it would pass vacuously" >&2
		exit 2
	fi
}
mk eng "Quarterly Report" "Revenue grew by twelve percent"
mk multi1 "Quarterly Report" "Revenue grew by twelve percent"
mk multi2 "Balance Sheet" "Total assets 98765"
magick "$tmp/multi1.pdf" "$tmp/multi2.pdf" "$tmp/multi.pdf"
mk de "Fussball Muenchen" "Strasse und Grusse aus Koeln"
mk ru "Привет Мир" "Страница номер пять"
mk rot "Tilted Page Test" "" "-rotate 4"
magick -size 1240x1754 xc:black -font $F -pointsize 84 -fill white \
	-annotate +100+400 "Inverted Scan" "$tmp/inv.jpg"
magick -quality 88 "$tmp/inv.jpg" "$tmp/inv.pdf"
# a PDF that already has a text layer
python3 - "$tmp/textlayer.pdf" <<'PY'
import sys
o=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
   b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>']
c=b'BT /F1 30 Tf 30 200 Td (Native Text Layer ABC) Tj ET'
o.append(b'<< /Length '+str(len(c)).encode()+b' >>\nstream\n'+c+b'\nendstream')
o.append(b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
b=b'%PDF-1.4\n'; x=[]
for i,v in enumerate(o,1):
    x.append(len(b)); b+=str(i).encode()+b' 0 obj\n'+v+b'\nendobj\n'
s=len(b); b+=b'xref\n0 '+str(len(o)+1).encode()+b'\n0000000000 65535 f \n'
for v in x: b+=('%010d 00000 n \n'%v).encode()
b+=b'trailer\n<< /Size '+str(len(o)+1).encode()+b' /Root 1 0 R >>\nstartxref\n'+str(s).encode()+b'\n%%EOF\n'
open(sys.argv[1],'wb').write(b)
PY

# ---- argument handling: no network needed ----
echo
echo "argument handling"
code() { # code <expected> <name> <args...>
	local want=$1 name=$2
	shift 2
	"$SCRIPT" "$@" >/dev/null 2>&1
	local got=$?
	[[ $got == "$want" ]] && ok "$name" || no "$name (exit $got, wanted $want)"
}
code 2 "no args exits 2"
code 0 "--help exits 0" --help
code 2 "missing file exits 2" "$tmp/does-not-exist.pdf"
code 2 "unknown flag exits 2" --nope "$tmp/eng.pdf"
cp "$tmp/eng.pdf" "$tmp/same.pdf"
code 2 "refuses to overwrite its own input" -O "$tmp/same.pdf" "$tmp/same.pdf"
[[ -z $(pdftotext "$tmp/same.pdf" - 2>/dev/null | tr -d '[:space:]') ]] &&
	ok "input left intact after refusal" || no "input left intact after refusal"
$SCRIPT /etc/hostname >"$tmp/bad.log" 2>&1
[[ $? == 1 ]] && grep -q errorCode "$tmp/bad.log" && ok "bad file type reports API error" ||
	no "bad file type reports API error (log: $(head -c 120 "$tmp/bad.log"))"

[[ ${QUICK:-0} == 1 ]] && {
	echo
	echo "quick: $pass passed, $fail failed"
	exit $((fail > 0))
}

# real network runs from here on

echo
echo "english OCR round trip"
ocr "$tmp/e" "$tmp/eng.pdf"
exists "english output pdf" "$tmp/e.pdf"
exists "english text sidecar" "$tmp/e.txt"
check "english recognizes headline" "Quarterly Report" "$tmp/e.txt"
check "english recognizes body" "twelve percent" "$tmp/e.txt"
pdftotext "$tmp/e.pdf" - >"$tmp/e_layer.txt" 2>/dev/null
check "text layer embedded in pdf" "Quarterly Report" "$tmp/e_layer.txt"

echo
echo "multi page"
ocr "$tmp/m" "$tmp/multi.pdf"
check "page 1 read" "Quarterly Report" "$tmp/m.txt"
check "page 2 read" "Total assets" "$tmp/m.txt"
[[ $(grep -c '@@@ Page' "$tmp/m.txt") == 2 ]] && ok "both pages reported" || no "both pages reported"

echo
echo "languages"
ocr "$tmp/de_o" -l deu "$tmp/de.pdf"
check "german recognized" "Muenchen" "$tmp/de_o.txt"
ocr "$tmp/ru_o" -l rus "$tmp/ru.pdf"
check "cyrillic recognized" "Мир" "$tmp/ru_o.txt"
# mixed-mode: two scripts on one page, only the joined language list gets both right
magick -size 1400x900 xc:white -font $F -pointsize 60 -annotate +80+200 "Привет Мир" \
	-pointsize 48 -annotate +80+380 "Order 55 line 7" "$tmp/mixru.jpg"
magick -quality 90 "$tmp/mixru.jpg" "$tmp/mixru.pdf"
ocr "$tmp/mru" -l rus+eng "$tmp/mixru.pdf"
check "mixed mode rus+eng gets cyrillic" "Привет" "$tmp/mru.txt"
check "mixed mode rus+eng gets latin" "Order 55" "$tmp/mru.txt"
ocr "$tmp/me" -l eng "$tmp/mixru.pdf"
if grep -qi "Привет" "$tmp/me.txt"; then
	no "eng alone fails on cyrillic (got it anyway)"
else
	ok "eng alone fails on cyrillic (confirms mixed mode matters)"
fi

echo
echo "preprocessing"
ocr "$tmp/rot_o" "$tmp/rot.pdf"
check "deskew on recovers tilted page" "Tilted Page Test" "$tmp/rot_o.txt"
$SCRIPT -d -O "$tmp/rotnd.pdf" --text "$tmp/rotnd.txt" "$tmp/rot.pdf" >/dev/null 2>&1
if grep -qi "Tilted" "$tmp/rotnd.txt"; then
	no "--no-deskew actually disabled deskew"
else
	ok "--no-deskew actually disabled deskew"
fi
ocr "$tmp/inv_o" "$tmp/inv.pdf"
check "inverted scan recognized" "Inverted Scan" "$tmp/inv_o.txt"

echo
echo "output formats"
$SCRIPT -o pdfa -O "$tmp/a.pdf" --text "$tmp/a.txt" "$tmp/eng.pdf" >/dev/null 2>&1
exists "pdfa output" "$tmp/a.pdf"
pdftotext "$tmp/a.pdf" - 2>/dev/null | grep -qi "Quarterly" && ok "pdfa keeps text" || no "pdfa keeps text"

echo
echo "force flag"
$SCRIPT -o "$tmp/fo.pdf" --text "$tmp/fo.txt" "$tmp/textlayer.pdf" >/dev/null 2>&1
if grep -q "@@@ Page" "$tmp/fo.txt" 2>/dev/null; then
	no "page with text layer skipped by default"
else
	ok "page with text layer skipped by default"
fi
ocr "$tmp/fi" -F "$tmp/textlayer.pdf"
check "--force OCRs existing text layer" "Native Text Layer" "$tmp/fi.txt"

echo
echo "multiple inputs"
mkdir -p "$tmp/multi_out"
# several files fan out into one job each; -O is the output directory
$SCRIPT -O "$tmp/multi_out" "$tmp/multi1.pdf" "$tmp/multi2.pdf" >"$tmp/multi.log" 2>&1 ||
	no "two inputs -> exit 0"
if [[ $(ls "$tmp/multi_out"/*.pdf 2>/dev/null | wc -l) == 2 ]]; then
	ok "two inputs -> two pdfs"
else
	no "two inputs -> two pdfs (got: $(ls "$tmp/multi_out" 2>/dev/null | tr '\n' ' '))"
fi
[[ $(ls "$tmp/multi_out"/*.txt 2>/dev/null | wc -l) == 2 ]] &&
	ok "two inputs -> two text sidecars" || no "two inputs -> two text sidecars"
check "first input has text" "Quarterly Report" "$tmp/multi_out/multi1_ocr.txt"
check "second input has text" "Total assets" "$tmp/multi_out/multi2_ocr.txt"
# one job per file means concurrent workers; the fan-out must not share a session
[[ $(grep -c 'job ocrPdf_' "$tmp/multi.log") == 2 ]] &&
	ok "one job per input" || no "one job per input (log: $(tr '\n' ' ' < "$tmp/multi.log"))"
code 2 "--text refused with several files" --text "$tmp/nope.txt" "$tmp/multi1.pdf" "$tmp/multi2.pdf"
ocr "$tmp/j" -j "$tmp/multi1.pdf" "$tmp/multi2.pdf"
[[ $(grep -c '@@@ Page' "$tmp/j.txt") == 2 ]] && ok "--join merges into one pdf" || no "--join merges into one pdf"

echo
echo "env defaults and odd paths"
PDF24_OCR_LANG=deu ocr "$tmp/env" "$tmp/de.pdf"
# the de fixture is rasterized ASCII on purpose, so the assertion is ASCII too
check "PDF24_OCR_LANG picks language" "Koeln" "$tmp/env.txt"
cp "$tmp/de.pdf" "$tmp/my scan (2024) ünïcode.pdf"
ocr "$tmp/u" -l deu "$tmp/my scan (2024) ünïcode.pdf"
check "spaces/parens/unicode in filename" "Koeln" "$tmp/u.txt"
cp "$tmp/eng.pdf" "$tmp/default_name.pdf"
$SCRIPT "$tmp/default_name.pdf" >/dev/null 2>&1
exists "default output name" "$tmp/default_name_ocr.pdf"
exists "default text name" "$tmp/default_name_ocr.txt"
# no -O at all, so the default name and its extension must follow -o
cp "$tmp/eng.pdf" "$tmp/pdfa_default.pdf"
"$SCRIPT" -o pdfa "$tmp/pdfa_default.pdf" >/dev/null 2>&1
[[ -f $tmp/pdfa_default_ocr.pdfa ]] && ok "pdfa default extension" ||
	no "pdfa default extension (got: $(ls "$tmp"/pdfa_default* 2>/dev/null | tr '\n' ' '))"
head -c 5 "$tmp/pdfa_default_ocr.pdfa" 2>/dev/null | grep -q '%PDF-' &&
	ok "pdfa writes real pdf bytes" || no "pdfa writes real pdf bytes"

echo
echo "images as input"
ocr "$tmp/img" "$tmp/eng.jpg"
check "jpg input recognized" "Quarterly Report" "$tmp/img.txt"

echo
echo "$pass passed, $fail failed"
exit $((fail > 0))
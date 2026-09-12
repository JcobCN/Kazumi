# ddddocr captcha OCR model

The **ddddocr** captcha classification model (MIT license,
https://github.com/sml2h3/ddddocr), trained specifically on distorted captcha
glyphs. Replaces the previous PP-OCRv6 tiny det+rec pair, which is a
general-purpose print-text OCR and misreads twisted captcha characters.

## Files

| File | Size | Description |
|------|------|-------------|
| `ddddocr.onnx` | ~13.6 MB | Captcha classification model (CTC head) |
| `ddddocr_charset.json` | 57 KB | 8210-entry charset; index 0 = blank |

## Preprocessing contract

- Input `input1`: `[1,1,64,W]` float, grayscale, `x/255` in [0,1].
- Height fixed to 64; width = `int(w * 64 / h)` (aspect preserved, truncated).
- Output: `[26,1,8210]` CTC logits; greedy decode with blank = index 0.
- Captcha charsets are alphanumeric in practice: when a decoded step's best
  character is not `[0-9a-zA-Z]`, fall back to that step's best alphanumeric
  character instead of dropping the position.

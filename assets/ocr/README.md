# PP-OCRv6 tiny captcha OCR models

Baidu PaddleOCR **PP-OCRv6 tiny** detection + recognition models, converted to
ONNX by the PaddleOCR team, plus the character dictionary.

## Files

| File | Size | Description |
|------|------|-------------|
| `det.onnx` | ~1.8 MB | DBNet text detection (0.43M params) |
| `rec.onnx` | ~4.5 MB | SVTR text recognition + CTC head (1.1M params) |
| `ppocrv6_tiny_dict.txt` | 27 KB | 6905-char dictionary (`["blank"] + chars + " "`) |

## Source

- `det.onnx`: https://huggingface.co/PaddlePaddle/PP-OCRv6_tiny_det_onnx
- `rec.onnx`: https://huggingface.co/PaddlePaddle/PP-OCRv6_tiny_rec_onnx

License: **Apache-2.0** (Baidu PaddleOCR, https://github.com/PaddlePaddle/PaddleOCR)

## Preprocessing contract

- **det**: input `[1,3,H,W]` float; ImageNet normalization `(x/255 - mean)/std`
  with `mean=[0.485,0.456,0.406]`, `std=[0.229,0.224,0.225]`; long side capped
  at 736; output `[1,1,H,W]` probability map (DBPostProcess box_thresh=0.4,
  unclip_ratio=1.5).
- **rec**: input `[1,3,48,W]` float; normalization `(x/255 - 0.5)/0.5`
  ([-1,1]); width padded to a multiple of 16 with black; output
  `[1,seq_len,6906]` CTC logits; greedy decode with blank=0, char k -> dict[k-1].

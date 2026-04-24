#!/usr/bin/env python3
"""
TypelessMLX - Persistent MLX Whisper transcription server.
Communicates via newline-delimited JSON over stdin/stdout (JSON-RPC style).
"""
import sys
import json
import os
import platform
import re
import traceback

_HESITATION_RE = re.compile(
    r'(?<![^\s，。！？、])(?:呃+|嗯+|啊+|哦+|喔+|哎+)(?=[,，。！？、\s]|$)',
    re.UNICODE
)


def strip_hesitations(text: str) -> str:
    text = _HESITATION_RE.sub('', text)
    text = re.sub(r'[，、]\s*[，、]', '，', text)   # collapse duplicate punctuation
    text = re.sub(r'^\s*[，。、！？]\s*', '', text)   # strip leading punctuation
    return text.strip()

_PUNCTUATION_PROMPT = "以下是台灣中文語音辨識，請輸出帶有適當標點符號的文字。例如：今天天氣很好，我們去公園走走吧。"


def ensure_trailing_punctuation(text: str) -> str:
    """若文字結尾沒有標點符號，補上句號。"""
    if text and text[-1] not in '。？！…」』':
        return text + '。'
    return text

# Default model: local MLX-converted Breeze-ASR-25; fallback to HF repo
DEFAULT_MODEL = os.path.expanduser("~/.local/share/typelessmlx/models/breeze-asr-25-mlx")
FALLBACK_MODEL = "mlx-community/whisper-large-v3-mlx"


def running_on_apple_silicon() -> bool:
    machine = platform.machine() or ""
    return sys.platform == "darwin" and machine.lower().startswith("arm")


def send(data: dict):
    print(json.dumps(data, ensure_ascii=False), flush=True)


_qwen3_model = None
_qwen3_model_path = None


def transcribe_qwen3(audio_path: str, model_path: str, language: str | None,
                     remove_fillers: bool = False) -> str:
    global _qwen3_model, _qwen3_model_path
    from mlx_audio.stt.utils import load_model
    from mlx_audio.stt.generate import generate_transcription
    if _qwen3_model is None or _qwen3_model_path != model_path:
        sys.stderr.write(f"[TypelessMLX] Loading Qwen3-ASR model: {os.path.basename(model_path)}\n")
        sys.stderr.flush()
        _qwen3_model = load_model(model_path)
        _qwen3_model_path = model_path
    import tempfile
    tmp_path = os.path.join(tempfile.gettempdir(), f"typelessmlx_qwen3_{os.getpid()}")
    system = "請以繁體中文輸出語音辨識結果，加上適當標點符號，不要使用簡體中文。"
    if remove_fillers:
        system += "移除說話者的語音猶豫音（例如「呃」「嗯」「啊」），但保留所有有意義的詞彙。"
    result = generate_transcription(
        model=_qwen3_model,
        audio=audio_path,
        output_path=tmp_path,
        format="txt",
        system_prompt=system,
    )
    try:
        os.remove(tmp_path + ".txt")
    except OSError:
        pass
    text = (result.text if hasattr(result, "text") else str(result)).strip()
    return ensure_trailing_punctuation(text)


def transcribe(audio_path: str, model_path: str, language: str | None,
               initial_prompt: str | None = None, model_type: str = "whisper",
               remove_fillers: bool = False) -> str:
    if model_type == "qwen3":
        return transcribe_qwen3(audio_path, model_path, language, remove_fillers)
    import mlx_whisper
    use_fp16 = model_type == "whisper" and running_on_apple_silicon()
    if use_fp16:
        sys.stderr.write("[TypelessMLX] Apple Silicon detected, enabling fp16\n")
        sys.stderr.flush()
    result = mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo=model_path,
        language=language or None,
        initial_prompt=initial_prompt or _PUNCTUATION_PROMPT,
        verbose=False,
        fp16=use_fp16,
    )
    text = result.get("text", "").strip()
    if remove_fillers:
        text = strip_hesitations(text)
    return ensure_trailing_punctuation(text)


def resolve_model(requested: str | None) -> str:
    if requested and requested.strip():
        return requested.strip()
    # Use local Breeze-ASR-25 if converted, else fallback
    if os.path.isdir(DEFAULT_MODEL):
        return DEFAULT_MODEL
    return FALLBACK_MODEL


def main():
    # Signal Swift that we're ready
    send({"status": "ready"})
    sys.stderr.write("[TypelessMLX] Python backend ready\n")
    sys.stderr.write(f"[TypelessMLX] Inference precision: {'fp16' if running_on_apple_silicon() else 'fp32'} (arch: {platform.machine()})\n")
    sys.stderr.flush()

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            sys.stderr.write(f"[TypelessMLX] JSON parse error: {e}\n")
            sys.stderr.flush()
            continue

        req_id = req.get("id", "")
        action = req.get("action", "")

        try:
            if action == "ping":
                send({"id": req_id, "status": "pong"})

            elif action == "transcribe":
                audio_path = req.get("audio_path", "")
                if not audio_path or not os.path.exists(audio_path):
                    send({"id": req_id, "text": "", "error": f"Audio file not found: {audio_path}"})
                    continue

                model = resolve_model(req.get("model"))
                language = req.get("language")
                initial_prompt = req.get("initial_prompt")
                model_type = req.get("model_type", "whisper")
                remove_fillers = req.get("remove_fillers", False)

                sys.stderr.write(f"[TypelessMLX] Transcribing with model: {os.path.basename(model)}, type: {model_type}, lang: {language or 'auto'}, remove_fillers: {remove_fillers}\n")
                sys.stderr.flush()

                text = transcribe(audio_path, model, language, initial_prompt, model_type, remove_fillers)
                send({"id": req_id, "text": text, "error": None})

            else:
                send({"id": req_id, "error": f"Unknown action: {action}"})

        except Exception as e:
            error_msg = f"{type(e).__name__}: {e}"
            sys.stderr.write(f"[TypelessMLX] Error handling '{action}': {traceback.format_exc()}\n")
            sys.stderr.flush()
            send({"id": req_id, "text": "", "error": error_msg})


if __name__ == "__main__":
    main()

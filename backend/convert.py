#!/usr/bin/env python3
"""
Convert a HuggingFace Whisper model to MLX format for use with mlx_whisper.
Based on mlx-examples/whisper/convert.py (Apple Inc.)

Usage:
    python convert.py --hf-path MediaTek-Research/Breeze-ASR-25 --mlx-path ~/models/breeze-asr-25-mlx
"""
import argparse
import copy
import json
import os
import sys
from dataclasses import asdict
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import torch
from mlx.utils import tree_flatten, tree_map, tree_unflatten
from mlx_whisper import torch_whisper
from mlx_whisper.whisper import ModelDimensions, Whisper


def hf_to_pt(weights, config):
    """Map HuggingFace Transformers weight names to OpenAI Whisper weight names."""
    config = {
        "n_mels": config["num_mel_bins"],
        "n_audio_ctx": config["max_source_positions"],
        "n_audio_state": config["d_model"],
        "n_audio_head": config["encoder_attention_heads"],
        "n_audio_layer": config["encoder_layers"],
        "n_vocab": config["vocab_size"],
        "n_text_ctx": config["max_target_positions"],
        "n_text_state": config["d_model"],
        "n_text_head": config["decoder_attention_heads"],
        "n_text_layer": config["decoder_layers"],
    }

    def remap(k):
        k = k.replace("model.", "")
        k = k.replace(".layers", ".blocks")
        k = k.replace(".self_attn", ".attn")
        k = k.replace(".attn_layer_norm", ".attn_ln")
        k = k.replace(".encoder_attn.", ".cross_attn.")
        k = k.replace(".encoder_attn_layer_norm", ".cross_attn_ln")
        k = k.replace(".final_layer_norm", ".mlp_ln")
        k = k.replace(".q_proj", ".query")
        k = k.replace(".k_proj", ".key")
        k = k.replace(".v_proj", ".value")
        k = k.replace(".out_proj", ".out")
        k = k.replace(".fc1", ".mlp1")
        k = k.replace(".fc2", ".mlp2")
        k = k.replace("embed_positions.weight", "positional_embedding")
        k = k.replace("decoder.embed_tokens", "decoder.token_embedding")
        k = k.replace("encoder.layer_norm", "encoder.ln_post")
        k = k.replace("decoder.layer_norm", "decoder.ln")
        return k

    # token embeddings are shared with output projection
    weights.pop("proj_out.weight", None)
    weights = {remap(k): v for k, v in weights.items()}
    return weights, config


def load_hf_weights(hf_path: str):
    """Download and load weights from a HuggingFace repo."""
    from huggingface_hub import snapshot_download

    print(f"[INFO] Downloading {hf_path} from HuggingFace...", flush=True)
    local_path = snapshot_download(
        repo_id=hf_path,
        allow_patterns=["*.json", "pytorch_model.bin", "model.safetensors", "*.txt"],
    )
    local_path = Path(local_path)

    pt_path = local_path / "pytorch_model.bin"
    if pt_path.is_file():
        print("[INFO] Loading pytorch_model.bin...", flush=True)
        weights = torch.load(str(pt_path), map_location="cpu", weights_only=True)
    else:
        sf_path = local_path / "model.safetensors"
        print(f"[INFO] Loading model.safetensors...", flush=True)
        from safetensors.torch import load_file
        weights = load_file(str(sf_path))

    with open(local_path / "config.json") as f:
        config = json.load(f)

    return weights, config


def convert_hf_to_mlx(hf_path: str, mlx_path: str, dtype_str: str = "float16"):
    """Convert a HuggingFace Whisper model to MLX format."""
    dtype = mx.float16 if dtype_str == "float16" else mx.float32

    def remap_weight(key, value):
        # mlx_whisper uses mlp1/mlp2 directly (not mlp.0/mlp.2)
        # Conv1d: PyTorch (out, in, k) → MLX (out, k, in)
        if "conv" in key and hasattr(value, "ndim") and value.ndim == 3:
            if isinstance(value, torch.Tensor):
                value = value.permute(0, 2, 1)
            else:
                value = value.swapaxes(1, 2)
        if isinstance(value, torch.Tensor):
            value = mx.array(value.detach().float().numpy())
        elif not isinstance(value, mx.array):
            value = mx.array(value)
        return key, value.astype(dtype)

    # Load HF weights
    raw_weights, hf_config = load_hf_weights(hf_path)

    # Map to OpenAI/MLX weight names
    print("[INFO] Remapping weight names...", flush=True)
    weights, mlx_config = hf_to_pt(raw_weights, hf_config)

    # Remove positional embedding (computed, not stored)
    weights.pop("encoder.positional_embedding", None)

    # Convert weights: rename mlp + transpose conv
    print("[INFO] Converting weights to MLX format...", flush=True)
    mlx_weights = {}
    for k, v in weights.items():
        new_k, new_v = remap_weight(k, v)
        mlx_weights[new_k] = new_v

    # Build MLX model to verify
    print("[INFO] Verifying model structure...", flush=True)
    model_dims = ModelDimensions(**mlx_config)
    model = Whisper(model_dims, dtype)
    model.load_weights(list(mlx_weights.items()), strict=False)

    # Final weights from model
    final_weights = dict(tree_flatten(model.parameters()))

    # Save
    mlx_path = Path(mlx_path)
    mlx_path.mkdir(parents=True, exist_ok=True)

    print(f"[INFO] Saving to {mlx_path}...", flush=True)

    # Save as weights.safetensors (required by mlx_whisper load_models.py)
    mx.save_safetensors(str(mlx_path / "weights.safetensors"), final_weights)

    # Also save config.json
    config_out = dict(mlx_config)
    config_out["model_type"] = "whisper"
    with open(mlx_path / "config.json", "w") as f:
        json.dump(config_out, f, indent=4)

    print(f"[INFO] Saved weights.safetensors and config.json to {mlx_path}", flush=True)
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Convert HuggingFace Whisper model to MLX format")
    parser.add_argument("--hf-path", required=True, help="HuggingFace model repo ID")
    parser.add_argument("--mlx-path", required=True, help="Output MLX model directory")
    parser.add_argument("--dtype", default="float16", choices=["float16", "float32"],
                        help="Weight dtype (default: float16)")
    args = parser.parse_args()

    mlx_path = os.path.expanduser(args.mlx_path)

    try:
        success = convert_hf_to_mlx(args.hf_path, mlx_path, args.dtype)
        print(f"\n✅ Conversion complete! Model saved to: {mlx_path}", flush=True)
        sys.exit(0)
    except Exception as e:
        import traceback
        print(f"\n❌ Conversion failed: {e}", file=sys.stderr, flush=True)
        traceback.print_exc()
        sys.exit(1)

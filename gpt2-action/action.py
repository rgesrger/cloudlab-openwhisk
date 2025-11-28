from transformers import AutoTokenizer, AutoModelForCausalLM
import torch
import time
import sys
import json

# Global cache for warm starts
MODEL = None
TOKENIZER = None

def main(args):
    """
    args: dictionary, e.g. {"prompt": "Hello world"}
    Returns a dictionary with generated text, cold_start flag, and timings
    """
    global MODEL, TOKENIZER

    prompt = args.get("prompt", "Hello world")
    t0 = time.time()
    cold_start = False

    # Cold start: load model once
    if MODEL is None:
        cold_start = True
        t_load0 = time.time()
        
        TOKENIZER = AutoTokenizer.from_pretrained("distilgpt2")
        # FIX 1: Set pad token to eos token to silence warnings and handle padding
        TOKENIZER.pad_token = TOKENIZER.eos_token 
        
        MODEL = AutoModelForCausalLM.from_pretrained("distilgpt2").to("cpu")
        MODEL.eval()
        t_load1 = time.time()
    else:
        t_load0 = 0
        t_load1 = 0

    # Prepare input
    # FIX 2: Ensure padding and attention mask are created when tokenizing
    inputs = TOKENIZER(prompt, return_tensors="pt", padding=True, truncation=True) 
    print("in main")
    # Inference
    t_inf0 = time.time()
    with torch.no_grad():
        output_ids = MODEL.generate(
            inputs["input_ids"],
            attention_mask=inputs["attention_mask"], 
            # FIX 3: Use the model's explicit configuration IDs for stable generation
            eos_token_id=MODEL.config.eos_token_id,
            pad_token_id=MODEL.config.eos_token_id, 
            max_length=inputs["input_ids"].shape[1] + 40,
            do_sample=True,
            temperature=0.7
        )
    t_inf1 = time.time()

    # Decode
    text = TOKENIZER.decode(output_ids[0], skip_special_tokens=True)
    print("text", text)
    return {
        "text": text,
        "cold_start": cold_start,
        "timings": {
            "load_time": (t_load1 - t_load0) if cold_start else 0,
            "inference_time": t_inf1 - t_inf0,
            "total_time": time.time() - t0
        }
    }

# OpenWhisk entrypoint
if __name__ == "__main__":
    print("start inference")
    try:
        args = json.load(sys.stdin)
    except Exception:
        args = {}
        
    result = main(args)
    # print(json.dumps(result))
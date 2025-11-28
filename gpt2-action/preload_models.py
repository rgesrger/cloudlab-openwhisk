from transformers import AutoTokenizer, AutoModelForCausalLM
import os

# Make sure /models directory exists
os.makedirs("/models", exist_ok=True)

# Download tokenizer and model into /models
AutoTokenizer.from_pretrained("distilgpt2", cache_dir="/models")
AutoModelForCausalLM.from_pretrained("distilgpt2", cache_dir="/models")

#!/bin/bash

# ================================
# Configuration
# ================================
ACTION_NAME="gpt2"
PROMPTS=("Hello world" "Once upon a time" "Serverless testing" "Parallel request" "AI is cool")

# ================================
# Function to invoke the action
# ================================
invoke_action() {
    prompt="$1"
    echo "Invoking with prompt: '$prompt'"

    # Call OpenWhisk action
    result=$(wsk action invoke $ACTION_NAME --result --param prompt "$prompt")

    # Parse results
    cold=$(echo "$result" | grep '"cold_start"' | awk -F: '{print $2}' | tr -d ', ')
    load=$(echo "$result" | grep '"load_time"' | awk -F: '{print $2}' | tr -d ', ')
    inference=$(echo "$result" | grep '"inference_time"' | awk -F: '{print $2}' | tr -d ', ')
    total=$(echo "$result" | grep '"total_time"' | awk -F: '{print $2}' | tr -d ', ')
    text=$(echo "$result" | grep '"text"' | sed 's/.*"text": "\(.*\)".*/\1/')

    # Print summary
    echo "  Cold start: $cold"
    echo "  Load time: $load s | Inference time: $inference s | Total time: $total s"
    echo "  Generated text: $text"
    echo ""
}

# ================================
# Sequential invocations
# ================================
echo "=== Sequential invocations ==="
for prompt in "${PROMPTS[@]}"; do
    invoke_action "$prompt"
done

# ================================
# Parallel invocations
# ================================
echo "=== Parallel invocations ==="
pids=()
for prompt in "${PROMPTS[@]}"; do
    invoke_action "$prompt" &
    pids+=($!)
done

# Wait for all parallel invocations to finish
for pid in "${pids[@]}"; do
    wait $pid
done

echo "=== Simulation complete ==="

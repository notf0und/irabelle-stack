#!/bin/bash

# Function to remove quotes and trim whitespace from a string
clean_string() {
    echo "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//'
}

launch_stream() {
    local name="$1"
    local stream="$2"
    local port="$3"

    if [[ "$stream" != *"ok.ru"* ]]; then
        # Non-ok.ru streams: one-shot in background
        echo "Starting stream: $name on port $port"
        streamlink "$stream" best --player-continuous-http --player-external-http-port "$port" --player-external-http --http-timeout 180 --retry-streams 300 --retry-max 0 --retry-open 1000 --http-header "User-Agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36" &
        return
    fi

    # ok.ru streams: via warp proxy, same config as other streams
    echo "Starting stream: $name on port $port (via warp proxy)"
    streamlink "$stream" best --player-continuous-http --player-external-http-port "$port" --player-external-http --http-timeout 180 --retry-streams 300 --retry-max 0 --retry-open 1000 --http-proxy socks5://warp:1080 --ringbuffer-size 64M --stream-segment-threads 3 --stream-segment-timeout 30 --stream-segment-attempts 5 --http-header "User-Agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36" &
}

# If streams.yaml is provided as an environment variable, create the file
if [[ -n "$STREAMS_YAML_CONTENT" ]]; then
    echo "Using streams from environment variable."
    echo "$STREAMS_YAML_CONTENT" > /config/streams.yaml
fi

# Check if streams.yaml exists
if [[ ! -f /config/streams.yaml ]]; then
    echo "Error: No streams.yaml found in /config. Please provide a streams.yaml."
    exit 1
fi

# Array to store job PIDs
declare -a job_pids

# Path to the YAML file
yaml_file="/config/streams.yaml"

# Read the YAML file and execute streamlink for each entry
while IFS= read -r line; do
    if [[ $line == "- name:"* ]]; then
        name=$(clean_string "${line#*: }")
        read -r line
        stream=$(clean_string "${line#*: }")
        read -r line
        port=$(clean_string "${line#*: }")
        
        launch_stream "$name" "$stream" "$port"
        job_pid=$!
        job_pids+=($job_pid)
        echo "Started stream for $name (PID: $job_pid)"
    fi
done < "$yaml_file"

echo "All streams have been started."

# Keep the container running by waiting for background jobs
wait
# Use a lightweight Python image
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install dependencies
RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    libffi-dev \
    libssl-dev \
    python3-dev \
    ffmpeg \
    && apt-get clean

# Clone the latest Streamlink code from GitHub
RUN git clone https://github.com/streamlink/streamlink.git

# Switch to the streamlink directory
WORKDIR /app/streamlink

# Copy custom plugin into Streamlink's plugin directory
COPY glaztv.py /app/streamlink/src/streamlink/plugins/glaztv.py

# Install Streamlink with its dependencies
RUN pip install .

# Create a directory for configuration
RUN mkdir /config

# Copy the start_streams script into the image
COPY start_streams.sh /config/start_streams.sh

# Make the startup script executable
RUN chmod +x /config/start_streams.sh

# Default command to run the startup script
CMD ["/bin/bash", "/config/start_streams.sh"]

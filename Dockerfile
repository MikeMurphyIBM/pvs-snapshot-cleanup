# Use a lightweight Debian base image
FROM debian:stable-slim

SHELL ["/bin/bash", "-c"]   # <--- CRITICAL for consistent execution

# Set non-interactive mode for smooth dependency installation
ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/root
WORKDIR ${HOME}

# -----------------------------------------------------------
# Install dependencies (bash, curl, jq, coreutils)
# -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    jq \
    ca-certificates \
    coreutils \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------
# Install IBM Cloud CLI and PowerVS plugin
# -----------------------------------------------------------
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash

# Ensure the IBM Cloud CLI is on PATH
ENV PATH="/usr/local/ibmcloud/bin:/root/.bluemix:$PATH"

# Disable version check → avoids installer stopping builds
RUN ibmcloud config --check-version=false

# Install plugin repo and PowerVS plugin
RUN ibmcloud plugin repo-plugins
RUN ibmcloud plugin install power-iaas -f

# -----------------------------------------------------------
# Copy the runtime script
# -----------------------------------------------------------
COPY latest.sh /latest.sh

# Ensure script is executable + normalize line endings
RUN sed -i 's/\r$//' /latest.sh && chmod +x /latest.sh

# -----------------------------------------------------------
# Run script at container start
# -----------------------------------------------------------
CMD ["/latest.sh"]

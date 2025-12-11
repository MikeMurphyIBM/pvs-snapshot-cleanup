# Use a lightweight Debian base image
FROM debian:stable-slim

# Ensure RUN commands use bash (supports process substitution)
SHELL ["/bin/bash", "-c"]

# Set non-interactive mode for smooth dependency installation
ENV DEBIAN_FRONTEND=noninteractive

# Set HOME and working directory
ENV HOME=/root
WORKDIR ${HOME}

# -----------------------------------------------------------
# 1. Install Dependencies (bash, coreutils, curl, jq)
# -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    coreutils \
    curl \
    jq \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------
# 2. Install IBM Cloud CLI + PowerVS Plugin
# -----------------------------------------------------------
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash && \
    ibmcloud plugin install power-iaas -f

# -----------------------------------------------------------
# 3. Add Runtime Script
# -----------------------------------------------------------
COPY latest.sh .

RUN chmod +x latest.sh

# -----------------------------------------------------------
# 4. Run the Script
# -----------------------------------------------------------
CMD ["/root/latest.sh"]

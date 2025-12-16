FROM ghcr.io/falcondev-oss/actions-runner:latest

# Switch to root for installations
USER root

# Install Docker Engine (dockerd) and CLI for true Docker-in-Docker
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    iptables \
    supervisor \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && apt-get update \
    && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Create docker group and add runner user
RUN groupadd docker || true \
    && usermod -aG docker runner

# Copy dockerd wrapper script (handles socket permissions)
COPY dockerd-wrapper.sh /usr/local/bin/dockerd-wrapper.sh
RUN chmod +x /usr/local/bin/dockerd-wrapper.sh

# Create supervisor config for running dockerd
RUN mkdir -p /etc/supervisor/conf.d
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Define Node.js version to install
ARG NODE_VERSION=20.19.6

# Switch back to runner user
USER runner
WORKDIR /home/runner

# Install nvm and Node.js as runner user
ENV NVM_DIR="/home/runner/.nvm"
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install $NODE_VERSION \
    && nvm use $NODE_VERSION \
    && nvm alias default $NODE_VERSION

# Make nvm available in all shells
RUN echo 'export NVM_DIR="$HOME/.nvm"' >> /home/runner/.bashrc \
    && echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> /home/runner/.bashrc \
    && echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' >> /home/runner/.bashrc

# Copy our startup script and supervisor config
COPY --chown=runner:runner start.sh /home/runner/start.sh
RUN chmod +x /home/runner/start.sh

# Switch back to root to run supervisord (which will run dockerd as root and runner as runner user)
USER root

# Start supervisord which will run both dockerd and the runner
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
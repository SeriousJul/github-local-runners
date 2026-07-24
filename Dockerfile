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

# Install mingw-w64 so Rust can cross-compile to Windows targets, plus a native
# toolchain since build scripts/proc-macros still compile for the host during a cross build.
# nsis/wixl provide native-Linux Windows installer builders (makensis / wixl);
# msitools adds .msi inspection tools (msiinfo, msidump, etc).
RUN apt-get update && apt-get install -y \
    build-essential \
    gcc-mingw-w64-x86-64 \
    g++-mingw-w64-x86-64 \
    nsis \
    msitools \
    wixl \
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

# Install Rust via rustup as runner user, with the Windows cross-compile target.
# CARGO_TARGET_..._LINKER points the windows-gnu target at the mingw-w64 cross gcc,
# since rustc otherwise tries to invoke the native (Linux) gcc as the linker.
ENV RUSTUP_HOME="/home/runner/.rustup" \
    CARGO_HOME="/home/runner/.cargo" \
    PATH="/home/runner/.cargo/bin:${PATH}" \
    CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="x86_64-w64-mingw32-gcc"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable \
    && rustup target add x86_64-pc-windows-gnu

# cargo-wix: generates .wxs and drives the WiX Toolset to build .msi installers.
# NOTE: this only installs the cargo subcommand itself. It still shells out to WiX's
# candle/light (or the v4 `wix` dotnet tool), which isn't installed here — see chat.
RUN cargo install cargo-wix

# Copy our startup script and supervisor config
COPY --chown=runner:runner start.sh /home/runner/start.sh
RUN chmod +x /home/runner/start.sh

# Switch back to root to run supervisord (which will run dockerd as root and runner as runner user)
USER root

# Start supervisord which will run both dockerd and the runner
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
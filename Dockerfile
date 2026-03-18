# =============================================================================
# Dockerfile for Meltano elt_mssql_sage
# Uses the full meltano image: includes MSSQL connectors and build tools
# needed by tap-mssql (driver_type: pymssql).
#
# Full image is required for MSSQL connectivity (slim image excludes MSSQL).
# Python 3.11: pymssql has binary wheels for 3.11 → installs cleanly, no compilation.
# =============================================================================

ARG MELTANO_IMAGE=meltano/meltano:latest-python3.11
FROM $MELTANO_IMAGE

# WORKDIR /project and ENTRYPOINT ["meltano"] are already set by the base image

# Copy only meltano config files (not .env, not .meltano/)
COPY meltano.yml .
COPY plugins/ plugins/

# Install all taps + targets at build time
RUN meltano install

# Fix: inject setuptools into each plugin venv (singer_sdk's 'fs' lib needs pkg_resources)
# Meltano 4.x uses uv for venv management
RUN for venv_dir in /project/.meltano/extractors/*/venv /project/.meltano/loaders/*/venv; do \
        if [ -d "$venv_dir" ]; then \
            uv pip install --python "$venv_dir/bin/python" "setuptools<71"; \
        fi \
    done

ENV MELTANO_PROJECT_READONLY=1

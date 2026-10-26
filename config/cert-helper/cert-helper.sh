#!/bin/sh
# ===================================================================
# Certificate Helper Script
# ===================================================================
# This script watches the domains.conf file and generates certificates
# for new domains. It will also check for either expiring, or expired
# certificates and regenerate them if necessary.
# ===================================================================

# Allow environment variables to override the default values.
DOMAINS_FILE="${DOMAINS_FILE:-/config/domains.conf}"
DOMAINS_EXAMPLE_FILE="${DOMAINS_EXAMPLE_FILE:-/config/domains.example.conf}"
CERTS_DIR="${CERTS_DIR:-/certs}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
RENEWAL_THRESHOLD_DAYS="${RENEWAL_THRESHOLD_DAYS:-30}"
CERT_CHECK_INTERVAL="${CERT_CHECK_INTERVAL:-86400}"
CERT_VALIDITY_DAYS="${CERT_VALIDITY_DAYS:-365}"
CLEANUP_ORPHANED="${CLEANUP_ORPHANED:-true}"

# Root CA settings.
# A single local Root CA is generated once and used to sign every per-domain
# leaf certificate. Trusting this Root CA once is sufficient for all current
# and future domains; per-domain trust-store entries are no longer required.
CA_CERT="${CA_CERT:-${CERTS_DIR}/local-root-ca.crt}"
CA_KEY="${CA_KEY:-${CERTS_DIR}/local-root-ca.key}"
CA_SERIAL="${CA_SERIAL:-${CERTS_DIR}/local-root-ca.srl}"
CA_VALIDITY_DAYS="${CA_VALIDITY_DAYS:-3650}"
CA_CN="${CA_CN:-Docker Infra Local Root CA}"
LEAF_VALIDITY_DAYS="${LEAF_VALIDITY_DAYS:-${CERT_VALIDITY_DAYS}}"

should_stop=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

shutdown() {
    log "Received shutdown signal, stopping..."
    should_stop=1
}

# Set signal handlers for graceful shutdown.
trap shutdown TERM INT

# Initialize the domains.conf file from the example if it doesn't exist.
init_domains_file() {
    if [ ! -f "$DOMAINS_FILE" ]; then
        if [ -f "$DOMAINS_EXAMPLE_FILE" ]; then
            log "Creating $DOMAINS_FILE from example file..."
            cp "$DOMAINS_EXAMPLE_FILE" "$DOMAINS_FILE"
            log "Created domains.conf from example file"
        else
            # Just in case the user removed the example file.
            log "Warning: Neither $DOMAINS_FILE nor $DOMAINS_EXAMPLE_FILE found"
        fi
    fi
}

# Ensure that the local Root CA exists and is valid.
# This CA is generated once on first run and used to sign every per-domain
# leaf certificate. It persists across container restarts in the certs dir.
ensure_root_ca() {
    if [ -f "$CA_CERT" ] && [ -f "$CA_KEY" ]; then
        # Validate that the existing CA cert is not expired.
        if openssl x509 -in "$CA_CERT" -noout -checkend 0 2>/dev/null; then
            log "Root CA is valid: $CA_CERT"
            return 0
        else
            log "Root CA has expired, regenerating..."
        fi
    else
        log "Root CA not found, generating..."
    fi

    openssl req -x509 \
        -nodes \
        -subj "/CN=$CA_CN" \
        -newkey rsa:4096 \
        -keyout "$CA_KEY" \
        -out "$CA_CERT" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -days "$CA_VALIDITY_DAYS"

    if [ $? -eq 0 ]; then
        chmod 600 "$CA_KEY"
        log "Successfully generated Root CA: $CA_CERT"
    else
        log "ERROR: Failed to generate Root CA"
        return 1
    fi
}

# Check if the certificate is expired, or is expiring soon.
# If a renewal is needed, return 0. Otherwise return 1 if the cert is valid.
check_cert_expiration() {
    crt_file="$1"

    # We'll need to create a cert if it doesn't exist.
    if [ ! -f "$crt_file" ]; then
        return 0
    fi

    # Deternine how long before the expiration date the cert should be renewed.
    threshold_seconds=$((RENEWAL_THRESHOLD_DAYS * 24 * 60 * 60))

    # Use OpenSSL's -checkend option to check expiration.
    # If this command succeeds, it means that the cert is valid.
    # When it fails, it means that the cert will expire within the threshold (or already has).
    if openssl x509 -in "$crt_file" -noout -checkend "$threshold_seconds" 2>/dev/null; then
        return 1
    fi

    # Determine if the cert has already expired, or is expiring soon.
    # This is only for logging purposes to tell the user why it is being renewed.
    if openssl x509 -in "$crt_file" -noout -checkend 0 2>/dev/null; then
        log "Certificate expiring soon (within ${RENEWAL_THRESHOLD_DAYS} days)"
    else
        log "Certificate has expired"
    fi

    return 0
}

generate_cert() {
    domain="$1"
    key_file="${CERTS_DIR}/${domain}.key"
    crt_file="${CERTS_DIR}/${domain}.crt"
    
    # Check if the certificate exists, and if it is still valid.
    if [ -f "$key_file" ] && [ -f "$crt_file" ]; then
        if check_cert_expiration "$crt_file"; then
            log "Regenerating certificate for: $domain"
        else
            log "Certificate is valid for: $domain"
            return 0
        fi
    else
        log "Generating new certificate for: $domain"
    fi

    # Generate the domain private key.
    openssl genrsa -out "$key_file" 4096 2>/dev/null
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to generate key for: $domain"
        return 1
    fi
    chmod 600 "$key_file"

    # Generate a Certificate Signing Request for the domain.
    csr_file="${CERTS_DIR}/${domain}.csr"
    openssl req -new -key "$key_file" -subj "/CN=$domain" -out "$csr_file" 2>/dev/null
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to generate CSR for: $domain"
        rm -f "$csr_file"
        return 1
    fi

    # Write the leaf certificate extensions to a temp file.
    # Alpine's sh does not support process substitution, so a temp file is used.
    ext_file="${CERTS_DIR}/${domain}.ext"
    printf '%s\n' \
        "basicConstraints=critical,CA:FALSE" \
        "keyUsage=critical,digitalSignature,keyEncipherment" \
        "extendedKeyUsage=serverAuth" \
        "subjectAltName=DNS:$domain" > "$ext_file"

    # Sign the CSR with the local Root CA to produce a leaf certificate.
    openssl x509 -req \
        -in "$csr_file" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
        -CAserial "$CA_SERIAL" \
        -CAcreateserial \
        -extfile "$ext_file" \
        -days "$LEAF_VALIDITY_DAYS" \
        -out "$crt_file" 2>/dev/null

    sign_status=$?

    # Clean up the temporary CSR and extensions files.
    rm -f "$csr_file" "$ext_file"

    if [ "$sign_status" -eq 0 ]; then
        log "Successfully generated certificate for: $domain"
    else
        log "ERROR: Failed to generate certificate for: $domain"
    fi
}

cleanup_orphaned_certs() {
    if [ "$CLEANUP_ORPHANED" != "true" ]; then
        return 0
    fi

    if [ ! -f "$DOMAINS_FILE" ]; then
        return 1
    fi

    valid_domains=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        domain=$(echo "$line" | tr -d '[:space:]')
        if [ -n "$domain" ]; then
            valid_domains="$valid_domains $domain"
        fi
    done < "$DOMAINS_FILE"

    orphaned_count=0
    for crt_file in "$CERTS_DIR"/*.crt; do
        [ -f "$crt_file" ] || continue

        domain=$(basename "$crt_file" .crt)
        key_file="${CERTS_DIR}/${domain}.key"

        # Never treat the local Root CA as an orphaned domain certificate.
        # It lives in the certs dir alongside the leaf certs but it should
        # not be listed in domains.conf with said leaf certs.
        case "$domain" in
            local-root-ca) continue ;;
        esac

        # Check if the domain is in the valid list.
        case " $valid_domains " in
            *" $domain "*)
                # If the domain is valid, keep the cert.
                ;;
            *)
                log "Removing orphaned certificate for: $domain"
                rm -f "$crt_file" "$key_file"
                orphaned_count=$((orphaned_count + 1))
                ;;
        esac
    done

    if [ "$orphaned_count" -gt 0 ]; then
        log "Removed $orphaned_count orphaned certificate(s)"
    fi
}

process_domains() {
    if [ ! -f "$DOMAINS_FILE" ]; then
        log "Domains file not found: $DOMAINS_FILE"
        return 1
    fi
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        case "$line" in
            ''|\#*) continue ;;
        esac

        # Trim whitespace
        domain=$(echo "$line" | tr -d '[:space:]')

        if [ -n "$domain" ]; then
            generate_cert "$domain"
        fi
    done < "$DOMAINS_FILE"
}

display_config() {
    log "Configuration:"
    log "  DOMAINS_FILE: $DOMAINS_FILE"
    log "  CERTS_DIR: $CERTS_DIR"
    log "  CHECK_INTERVAL: ${CHECK_INTERVAL}s"
    log "  RENEWAL_THRESHOLD_DAYS: $RENEWAL_THRESHOLD_DAYS"
    log "  CERT_CHECK_INTERVAL: ${CERT_CHECK_INTERVAL}s"
    log "  CERT_VALIDITY_DAYS: $CERT_VALIDITY_DAYS"
    log "  CLEANUP_ORPHANED: $CLEANUP_ORPHANED"
    log "  CA_CERT: $CA_CERT"
    log "  CA_KEY: $CA_KEY"
    log "  CA_VALIDITY_DAYS: $CA_VALIDITY_DAYS"
    log "  CA_CN: $CA_CN"
    log "  LEAF_VALIDITY_DAYS: $LEAF_VALIDITY_DAYS"
}

# Initialize the script.
# ----------------------
# We want to create the domain file from the example if it doesn't exist.
# Then we want to ensure the local Root CA is present (generated on first run).
# After that, showcase what the config setup looks like on stdout.
# Finally, start processing the domain list before setting up the watcher.
init_domains_file
ensure_root_ca
display_config
process_domains

# Continue to watch for changes and perform periodic checks.
last_checksum=""
last_cert_check=$(date +%s)

while [ "$should_stop" -eq 0 ]; do
    current_time=$(date +%s)

    # Check for domains file changes.
    if [ -f "$DOMAINS_FILE" ]; then
        current_checksum=$(md5sum "$DOMAINS_FILE" | cut -d' ' -f1)

        if [ "$current_checksum" != "$last_checksum" ]; then
            log "Domains file changed, processing..."
            process_domains
            cleanup_orphaned_certs
            last_checksum="$current_checksum"
        fi
    fi

    # Check the certificates on a schedule as well.
    time_since_last_check=$((current_time - last_cert_check))
    if [ "$time_since_last_check" -ge "$CERT_CHECK_INTERVAL" ]; then
        log "Performing scheduled certificate check..."
        process_domains
        cleanup_orphaned_certs
        last_cert_check=$current_time
    fi

    sleep "$CHECK_INTERVAL"
done

log "Certificate Helper stopped"